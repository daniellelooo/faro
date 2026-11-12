import AVFoundation
import AppKit
import FaroCore
import Observation

/// Estado de la grabación de reuniones, compartido por la ventana, el menú y la píldora.
@MainActor @Observable
final class MeetingController {
  var meetings: [Meeting] = []
  var current: Meeting?
  var liveSegments: [TranscriptSegment] = []
  var elapsed: Double = 0
  var isRecording: Bool { current?.status == .recording }
  var busyMessage: String?
  var isPaused = false
  /// Grupo donde se guardan las próximas grabaciones e importaciones.
  var nextGroup: String?
  /// Tiempo grabado antes de la pausa actual (lo que estuvo en pausa no cuenta).
  private var recordedBefore: Double = 0

  let store = MeetingStore()
  /// Respuestas en vivo a preguntas que cubren las notas de contexto del usuario.
  let copilotPanel = CopilotPanel()
  private(set) var copilotActive = false
  private let recorder = MeetingRecorder()
  private var transcriber: MeetingTranscriber?
  private var timer: Timer?
  private var activity: NSObjectProtocol?
  private var startDate = Date()
  weak var app: AppDelegate?

  init() {
    store.recoverInterrupted()
    reload()
  }

  func reload() { meetings = store.list() }

  var level: Float { recorder.level }

  func start(includeSystemAudio: Bool, copilot useCopilot: Bool = false) async {
    guard let app, case .ready = app.model.engine else {
      busyMessage = "El motor de voz todavía está cargando."
      return
    }
    var copilot: MeetingCopilot?
    if useCopilot {
      let folder = MeetingCopilot.folder(fromSetting: app.settings.copilotNotesFolder)
      let notes = folder.map { MeetingCopilot.loadKnowledge(from: $0) } ?? (text: "", names: [])
      if app.settings.localOnly || (app.apiKey ?? "").isEmpty {
        busyMessage = "El copiloto necesita la clave de API y que no esté activo el modo solo local."
      } else if folder == nil {
        busyMessage = "El copiloto está desactivado: elige la carpeta de notas en Ajustes. Grabando sin copiloto."
      } else if notes.names.isEmpty {
        busyMessage = "No hay notas .md en \(folder!.path): grabando sin copiloto."
      } else {
        copilot = MeetingCopilot(apiKey: app.apiKey ?? "", knowledge: notes.text)
        copilotPanel.reset(notes: notes.names)
      }
    }
    var m = Meeting(startedAt: Date(), includesSystemAudio: includeSystemAudio)
    m.group = MeetingGroups.normalized(nextGroup)
    m.status = .recording
    try? store.save(m)
    let store = self.store
    let id = m.id
    let panel = copilotPanel
    // Copia inmutable para el cierre que corre en otro hilo.
    let liveCopilot = copilot
    let mt = MeetingTranscriber(transcriber: app.transcriberForMeetings, sampleRate: AudioRecorder.sampleRate, dictionary: app.settings.dictionary,
                                minSegment: copilot == nil ? MeetingTranscriber.minSegment : 2,
                                maxSegment: copilot == nil ? MeetingTranscriber.maxSegment : 12) { [weak self] segments in
      // Se guarda cada tramo apenas sale: un cierre inesperado no pierde lo transcrito.
      Task { @MainActor [weak self] in
        guard var saved = store.load(id) else { return }
        saved.segments = segments
        try? store.save(saved)
        self?.liveSegments = segments
      }
      if let liveCopilot {
        Task {
          let answers = await liveCopilot.consider(segments)
          await MainActor.run { for a in answers { panel.add(a) } }
        }
      }
    }
    transcriber = mt
    recorder.onMixed = { mt.append($0) }
    liveSegments = []
    do {
      try await recorder.start(audioURL: store.recordingURL(id), includeSystemAudio: includeSystemAudio)
    } catch {
      busyMessage = "No se pudo usar el micrófono."
      try? store.delete(id)
      return
    }
    if includeSystemAudio && !recorder.usesSystemAudio {
      busyMessage = "Sin permiso para el audio del Mac: grabando solo el micrófono."
    }
    m.includesSystemAudio = recorder.usesSystemAudio
    try? store.save(m)
    current = m
    startDate = Date()
    elapsed = 0
    recordedBefore = 0
    isPaused = false
    // Que el Mac no se duerma mientras graba.
    activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Grabando una reunión")
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.isPaused else { return }
        self.elapsed = self.recordedBefore + Date().timeIntervalSince(self.startDate)
        app.overlay.state.meetingElapsed = self.elapsed
        app.overlay.state.level = self.recorder.level
      }
    }
    app.overlay.show(.meeting)
    copilotActive = copilot != nil
    if copilotActive { copilotPanel.show() }
    reload()
  }

  private func endCopilot() {
    copilotActive = false
    copilotPanel.state.listening = false
    copilotPanel.hide()
  }

  func stop(summarize: Bool = true) async {
    guard var m = current, let mt = transcriber, let app else { return }
    timer?.invalidate()
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = nil
    recorder.onMixed = nil
    await recorder.stop()
    app.overlay.show(.hidden)
    endCopilot()
    m.duration = isPaused ? recordedBefore : recordedBefore + Date().timeIntervalSince(startDate)
    isPaused = false
    app.overlay.state.meetingPaused = false
    m.status = .transcribing
    current = m
    try? store.save(m)
    reload()
    do {
      m.segments = try await mt.finish()
    } catch {
      m.error = error.localizedDescription
    }
    transcriber = nil
    current = nil
    try? store.save(m)
    reload()
    if summarize { await self.summarize(m.id) } else {
      m.status = .ready
      try? store.save(m)
      reload()
    }
  }

  func togglePause() {
    guard isRecording, let app else { return }
    if isPaused {
      do { try recorder.resume() } catch {
        busyMessage = "No se pudo reanudar el micrófono."
        return
      }
      startDate = Date()
      isPaused = false
    } else {
      recorder.pause()
      recordedBefore += Date().timeIntervalSince(startDate)
      elapsed = recordedBefore
      isPaused = true
    }
    app.overlay.state.meetingPaused = isPaused
    app.overlay.state.level = 0
    app.updateMenu()
  }

  /// Trae un audio grabado en otro lado (Notas de voz del iPhone, una grabadora) y lo transcribe y resume.
  func importAudio(_ url: URL) async {
    guard let app else { return }
    guard case .ready = app.model.engine else {
      busyMessage = "El motor de voz todavía está cargando."
      return
    }
    let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    var m = Meeting(startedAt: created, includesSystemAudio: false)
    m.group = MeetingGroups.normalized(nextGroup)
    m.status = .transcribing
    try? store.save(m)
    reload()
    let dest = store.recordingURL(m.id)
    let rate = AudioRecorder.sampleRate
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    do {
      // Se guarda una copia propia a 16 kHz (más liviana); el original no se toca.
      let samples = try await Task.detached { try Self.loadMono(url, sampleRate: rate) }.value
      try Self.writeAAC(samples, to: dest, sampleRate: rate)
      m.duration = Double(samples.count) / Double(rate)
      try? store.save(m)
      reload()
    } catch {
      m.status = .failed
      m.error = "No se pudo leer el audio: \(error.localizedDescription)"
      try? store.save(m)
      reload()
      return
    }
    await retranscribe(m.id)
  }

  nonisolated static func writeAAC(_ samples: [Float], to url: URL, sampleRate: Int) throws {
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
    var i = 0
    while i < samples.count {
      let n = min(65536, samples.count - i)
      let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
      buf.frameLength = AVAudioFrameCount(n)
      samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress! + i, count: n) }
      try file.write(from: buf)
      i += n
    }
  }

  /// Al cerrar Faro con una grabación en curso: se cierra el archivo de audio y la reunión queda para recuperar.
  func finishForQuit() {
    guard isRecording else { return }
    timer?.invalidate()
    recorder.onMixed = nil
    let recorder = self.recorder
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
      await recorder.stop()
      sem.signal()
    }
    _ = sem.wait(timeout: .now() + 2)
  }

  func discard() async {
    guard let m = current else { return }
    isPaused = false
    app?.overlay.state.meetingPaused = false
    timer?.invalidate()
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = nil
    recorder.onMixed = nil
    await recorder.stop()
    app?.overlay.show(.hidden)
    endCopilot()
    transcriber = nil
    current = nil
    try? store.delete(m.id)
    reload()
  }

  func summarize(_ id: UUID) async {
    guard var m = store.load(id), let app else { return }
    if app.settings.localOnly || m.segments.isEmpty {
      m.status = m.segments.isEmpty ? .failed : .ready
      if m.segments.isEmpty { m.error = "No se detectó voz en la grabación." }
      try? store.save(m)
      reload()
      return
    }
    m.status = .summarizing
    m.error = nil
    try? store.save(m)
    reload()
    do {
      m.summary = try await MeetingSummarizer(apiKey: app.apiKey).summarize(transcript: m.transcript, vocabulary: app.settings.words)
      m.status = .ready
    } catch {
      m.status = .ready
      m.error = "Sin resumen: \(error.localizedDescription)"
    }
    try? store.save(m)
    reload()
  }

  /// Vuelve a transcribir una grabación guardada con el proceso actual (útil para clases grabadas antes de las mejoras).
  func retranscribe(_ id: UUID) async {
    guard var m = store.load(id), let app, current == nil else { return }
    guard case .ready = app.model.engine else {
      busyMessage = "El motor de voz todavía está cargando."
      return
    }
    m.status = .transcribing
    m.error = nil
    try? store.save(m)
    reload()
    let rate = AudioRecorder.sampleRate
    let mt = MeetingTranscriber(transcriber: app.transcriberForMeetings, sampleRate: rate, dictionary: app.settings.dictionary) { _ in }
    do {
      let samples = try Self.loadMono(store.audioURL(id), sampleRate: rate)
      for i in stride(from: 0, to: samples.count, by: rate) { mt.append(Array(samples[i..<min(samples.count, i + rate)])) }
      m.segments = try await mt.finish()
    } catch {
      m.error = "No se pudo volver a transcribir: \(error.localizedDescription)"
    }
    try? store.save(m)
    reload()
    await summarize(id)
  }

  /// Lee un archivo de audio como muestras mono a la frecuencia pedida.
  nonisolated static func loadMono(_ url: URL, sampleRate: Int) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
    guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { throw CocoaError(.fileReadCorruptFile) }
    var out: [Float] = []
    let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32768)!
    var done = false
    while !done {
      let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 32768)!
      var error: NSError?
      let status = converter.convert(to: outBuf, error: &error) { _, inputStatus in
        do {
          try file.read(into: inBuf)
          if inBuf.frameLength == 0 {
            inputStatus.pointee = .endOfStream
            return nil
          }
          inputStatus.pointee = .haveData
          return inBuf
        } catch {
          inputStatus.pointee = .endOfStream
          return nil
        }
      }
      if let error { throw error }
      if let ch = outBuf.floatChannelData, outBuf.frameLength > 0 {
        out.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
      }
      if status == .endOfStream || (status == .inputRanDry && outBuf.frameLength == 0) { done = true }
    }
    return out
  }

  func toggleTask(_ meetingID: UUID, _ task: MeetingTask) {
    guard var m = store.load(meetingID), var s = m.summary, let i = s.tasks.firstIndex(of: task) else { return }
    s.tasks[i].done.toggle()
    m.summary = s
    try? store.save(m)
    reload()
  }

  func delete(_ id: UUID) {
    try? store.delete(id)
    reload()
  }

  func delete(_ ids: Set<UUID>) {
    for id in ids where id != current?.id { try? store.delete(id) }
    reload()
  }

  func setGroup(_ group: String?, for ids: Set<UUID>) {
    let g = MeetingGroups.normalized(group)
    for id in ids {
      guard var m = store.load(id) else { continue }
      m.group = g
      try? store.save(m)
    }
    reload()
  }

  func renameGroup(_ old: String, to new: String) {
    setGroup(new, for: Set(meetings.filter { $0.group == old }.map(\.id)))
    if nextGroup == old { nextGroup = MeetingGroups.normalized(new) }
  }

  var groupNames: [String] { MeetingGroups.names(meetings) }
}
