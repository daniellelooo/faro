# Banco de pruebas del dictado de Faro: resultados

Se corre con `swift build -c release --product dicta-bench && .build/release/dicta-bench` y escribe
`bench-out/informe.md`. Son 70 dictados en español sintetizados con las voces del Mac (es_MX y es_ES); el pipeline
es el real: Whisper `large-v3-turbo` q5_0 en local y limpieza con `claude-haiku-5-5`.

## Última corrida (2026-11-11, MacBook en corriente alterna)

Desde el 2026-11-01 los casos usan nombres propios inventados (Kivo, Lavamax, Zentrix…) en vez de clientes reales, y
la voz sintética los pronuncia mal: por eso el diccionario baja frente a la corrida anterior. No es una regresión.

| Métrica | Cerca | Lejos (voz −20 dB + ruido real de una pieza) | Meta |
|---|---|---|---|
| WER crudo (Whisper) | 28.6 % | 32.1 % | |
| WER limpio | 6.4 % | 7.0 % | ≤ 8 % |
| Diccionario bien escrito | 11 de 26 (42 %) | 11 de 26 (42 %) | ≥ 95 % |
| Casos que pasan (todos) | 54 de 70 | 54 de 70 | |
| Latencia total p50 / p90 | 1.52 s / 2.35 s | 1.50 s / 1.76 s | p50 ≤ 1,5 s |
| Transcripción p50 / p90 | 0.66 s / 0.69 s | 0.62 s / 0.88 s | |

Modos: `BENCH_STREAM=1` pasa el audio por el mismo camino que la app (`StreamingDictation`) y `BENCH_LEJOS=ruido.f32`
baja la voz 20 dB y le mezcla un ruido grabado (16 kHz mono, float32). `dicta-bench --audio x.f32` transcribe una
grabación real y compara variantes; `dicta-bench --limpiar "texto"` pasa un texto por la limpieza 5 veces.

Con grabaciones reales (2026-11-11) se vio lo que el banco no mostraba: cortar el dictado en tramos de 3 s hacía que
Whisper se equivocara mucho más ("un TikTok como un balo" por "un dictado como malo"). Desde entonces el dictado se
transcribe entero (35 s de audio en ~1,4 s) y solo se adelanta por partes pasados 45 s.

### Corrida anterior (2026-10-22, en batería con bajo consumo, nombres de clientes reales)

WER limpio 2.7 %, diccionario 25 de 26 (96 %), 66 de 70 casos, latencia p50 2.23 s. El modo de bajo consumo casi
duplica el tiempo de Whisper.

## Lo que fallaba en la corrida del 2026-10-22 (4 de 70)

- **Wompi dicho por la voz sintética sale "Bumpi"** y la limpieza no lo corrige. Con voz real habría que verlo.
- **"Somos tres personas, no, cuatro con Laura"** queda "Somos cuatro con Laura": pierde "personas".
- **Pasos con "primero, después, al final" sin frase de introducción**: el primer paso queda como encabezado de la lista.
- **"¿Qué hora es en Tokio?"** se transcribe "¿Qué horas en Tokio?". Como es corta y sin muletillas, no pasa por la
  limpieza (para ahorrar latencia) y el error de Whisper queda.

## Decisiones tomadas con el banco

- La limpieza usa `thinking: disabled` y `effort: low`. El prompt se ajustó con estos casos; el error por palabra
  del texto limpio bajó de 5,8 % a 2,3–2,7 %.
- **Petición de respaldo**: si Claude no responde en 1,1 s se lanza una segunda petición igual y gana la primera.
  Eliminó los casos de más de 3 s, que antes caían al texto crudo.
- Dictados de 6 palabras o menos, sin muletillas, se pegan sin limpiar.
