# PlezyVision — Fondo ambiental dinámico y transiciones sincronizadas

**Estado:** mejora validada satisfactoriamente en Fire TV Stick 4K (ARM32), el 16 de noviembre de 2026.

## Resumen

PlezyVision incorpora un fondo ambiental dinámico que toma como referencia los colores del fanart de la película o serie seleccionada. El degradado acompaña visualmente a la ilustración y cambia suavemente al seleccionar otro título.

La transición del fanart y la del fondo ambiental funcionan conjuntamente, sin necesidad de seleccionar «Detalles completos» en los ajustes de efectos visuales.

## Funcionamiento

- **Colores del contenido:** se obtiene un color representativo de la ilustración y se combina con el color de fondo del tema.
- **Degradado espacial:** se emplea una distribución de varios puntos y distintas intensidades, en lugar de teñir uniformemente toda la pantalla.
- **Transiciones:** al cambiar de título, el fanart realiza un fundido cruzado y el degradado interpola sus colores. La duración objetivo es de **280 ms**.
- **Fire TV ARM32:** cuando está activado el fondo ambiental, la transición del fanart conserva su duración aunque el perfil automático del dispositivo reduzca otros efectos visuales. Se sigue respetando la preferencia de accesibilidad que desactiva las animaciones.
- **Tráileres:** se mantiene el comportamiento existente del reproductor de tráileres y su continuidad al entrar y salir de los detalles del mismo título.

## Activación

En **Ajustes → Apariencia**, activar **«Fondo ambiental dinámico»**.

La opción funciona con el modo de efectos visuales **«Automático»**: no activa «Detalles completos» ni sus demás efectos.

## Archivos principales

- `lib/widgets/ambient_artwork_palette.dart`: análisis y selección del color representativo.
- `lib/widgets/ambient_spotlight_tint.dart`: composición y animación del degradado ambiental.
- `lib/widgets/tv_spotlight_background.dart`: integración del fondo en las pantallas de selección.
- `lib/widgets/cycling_media_backdrop.dart`: transición entre imágenes del fanart.
- `lib/services/settings_service.dart`: persistencia de la preferencia.
- `lib/screens/settings/appearance_settings_screen.dart`: interruptor de Apariencia.

## Validación

**Entorno:** Fire TV Stick 4K con aplicación ARM32, modo visual «Automático».

**Resultado comunicado por el usuario:** selección de colores y degradado satisfactorios; transición del fanart y del degradado correcta y perfectamente sincronizada.

La compilación de GitHub Actions correspondiente a la corrección final `8aad4a8` finalizó correctamente.

## Alcance y precauciones

- Se conserva la configuración general de rendimiento del dispositivo.
- No se modifica la densidad de biblioteca ni el tamaño de fuentes, pósteres o insignias.
- La opción de tamaño de texto propuesta anteriormente **no se ha implementado**, porque el usuario prefiere el resultado de «Densidad de biblioteca → Cómodo».
- La validación visual indicada corresponde al dispositivo probado; no presupone pruebas en todos los modelos Android TV.

## Referencias

Corrección final de la transición: `8aad4a8c8fee6e005b6063c796a7419469f5b246`.

PlezyVision es una adaptación independiente de [Plezy](https://github.com/edde746/plezy), distribuida conforme a la licencia del proyecto original.
