# Banco de pruebas de Dicta: resultados

Se corre con `swift build -c release --product dicta-bench && .build/release/dicta-bench` y escribe
`bench-out/informe.md`. Son 70 dictados en español sintetizados con las voces del Mac (es_MX y es_ES); el pipeline
es el real: Whisper `large-v3-turbo` q5_0 en local y limpieza con `claude-haiku-5-5`.

## Última corrida (2026-10-22, MacBook M5 en batería con modo de bajo consumo)

| Métrica | Valor | Meta |
|---|---|---|
| WER crudo (Whisper) | 25.8 % | |
| WER limpio | 2.7 % | ≤ 8 % |
| Diccionario bien escrito | 25 de 26 (96 %) | ≥ 95 % |
| autocorreccion que pasan | 9 de 10 | todos |
| lista que pasan | 4 de 5 | todos |
| instruccion que pasan | 9 de 10 | todos |
| Casos que pasan (todos) | 66 de 70 | |
| Respaldo al texto crudo | 0 | 0 |
| Latencia total p50 / p90 | 2.23 s / 2.93 s | p50 ≤ 1,5 s |
| Transcripción p50 / p90 | 1.38 s / 1.94 s | |
| Limpieza p50 / p90 | 0.85 s / 1.19 s | |


En corriente alterna, sin modo de bajo consumo, la transcripción midió 0,72 s de mediana y el total 1,58 s
(corrida anterior). El modo de bajo consumo casi duplica el tiempo de Whisper.

## Lo que todavía falla (4 de 70)

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
