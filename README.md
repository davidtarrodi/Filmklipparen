# Filmklipparen

Ett enkelt men riktigt klippprogram för barn (10–12 år), byggt för en **MacBook Pro 13" (sent 2013)
med macOS 11 Big Sur**. Skrivet i Swift med Apples egna AVFoundation och SwiftUI: inga
extra bibliotek, ingen Homebrew. H.264 spelas och sparas med datorns hårdvara.

## Det här kan den

**Tre videospår** (det översta ligger ovanpå):
- **Text**: knappen *Text* lägger en text där det gula strecket står. Skriv, välj typsnitt, fet stil,
  storlek och färg till höger. Dra texten dit du vill i bilden, dra i det gula hörnet för storlek.
- **Bild**: stillbilder (även iPhone-bilder i HEIC) ovanpå filmen. Dra för att flytta, gula hörnet
  för storlek, eller *Hela bilden* / *Fyll rutan*.
- **Film**: filmklippen efter varandra. Dra för att byta ordning, dra i kanterna för att korta.
  En liten bild längst till vänster på varje klipp följer med när man scrollar.

**Tre ljudspår**: *Filmljud* (ljudet i filmklippen, nivå per klipp), *Musik* (en låt under hela
filmen, upprepas och tonas ut) och *Ljudeffekter* (läggs där strecket står, dras och kortas fritt).

Text, bild och ljudeffekter dras fritt i tiden och i kanterna; de fastnar mot strecket och mot
andra kanter. Inget får ligga omlott i samma spår. Fortsätter en bild eller text efter sista
filmklippet blir det svart bakom. Äldre projekt med text på filmklippen flyttas automatiskt till textspåret.

- **Klipp här** (K) delar det valda (eller filmklippet) där strecket står.
- **Ångra / Gör om** (⌘Z / ⇧⌘Z), många steg. Arbetet **sparas av sig självt**.
- **Spara filmen**: en MP4 i 1080p i mappen *Filmer*, med bilder och texter inbrända.
- Dra filer till fönstret: filmer, bilder och ljud hamnar i rätt spår (en lång låt blir musik).

**Tangenter:** mellanslag spela/pausa · ← → en bild (med Shift en sekund) · K klipp ·
backsteg ta bort det valda · Esc välj bort.

## Bygga

Enklast: appen byggs automatiskt på GitHub vid varje ändring. Den färdiga appen hamnar som
`Filmklipparen.zip` i grenen `dist`, tillsammans med provbilder. Bygget provkör också sparandet av en film
(bild, ljud, musik, texter, stående mobilfilm) och startar appen en gång.

Att bygga själv på MacBooken kräver Swift 5.5 eller senare (Command Line Tools 13 eller nyare).

### Direkt på MacBooken

1. Packa upp mappen, t.ex. i *Hämtade filer*.
2. Dubbelklicka `build.command`. (Säger macOS att den inte kan öppnas: högerklicka → Öppna.)
3. Första gången ber den om Apples utvecklarverktyg (*Command Line Tools*). Klicka Installera,
   vänta, och dubbelklicka `build.command` igen.
4. Appen hamnar i *Program* och startar.

Fungerar inte installationen av utvecklarverktygen kan de hämtas med ett Apple-ID från
developer.apple.com/download/all: *Command Line Tools for Xcode 13.2* eller senare som fungerar på Big Sur.

### På en nyare Mac (Apple silicon), och flytta över

Kör `./build.sh --no-install`. Appen blir *universal* (både Intel och Apple silicon) och ligger i
`build/Filmklipparen.app`, packad som `build/Filmklipparen.zip`. Flytta zip-filen till MacBooken
(AirDrop eller USB-minne), packa upp, lägg appen i Program och öppna den första gången med
högerklick → Öppna (den är bara lokalt signerad).

## Bra att veta

- **iPhone-film i HEVC (H.265)**: en MacBook från 2013 har ingen hårdvara för HEVC, så den
  spelas av processorn och kan hacka i 4K. Ställ in iPhonen på *Mest kompatibel*
  (Inställningar → Kamera → Format) så blir det H.264, eller filma i 1080p.
- Förhandsvisningen räknas i 720p för att gå lätt; den sparade filmen blir 1080p.
- Bildfrekvensen i den sparade filmen är 30 bilder/s.

## Kod

| Fil | Vad den gör |
|---|---|
| `Sources/Model.swift` | Filmen och klippen (sparas som JSON i `~/Library/Application Support/Filmklipparen`) |
| `Sources/MovieBuilder.swift` | Bygger ihop klippen med AVFoundation: bild, ljud, musik, texter |
| `Sources/Editor.swift` | Uppspelning, ångra, klippa, flytta, lägga till filer, spara filmen |
| `Sources/Views.swift` | Fönstret, knappar, bilden med flyttbara bilder och texter |
| `Sources/Timeline.swift` | Tidslinjen med sex spår, kanter att dra i |
| `Sources/Inspector.swift` | Inställningarna till höger för det som är valt |
| `Sources/App.swift` | Startpunkten |

## Idéer till nästa version

- Stillbilder i filmen (foton), övertoningar mellan klipp, flera filmer/projekt att välja mellan,
  ljudinspelning (berättarröst), snabbare/långsammare klipp, färgfilter.
