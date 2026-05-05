# MC14500 Bit-Slice CPU — Eine 8-Bit-CPU aus acht 1-Bit-Prozessoren

## Die Idee

Was wäre, wenn man acht Motorola MC14500 1-Bit-Prozessoren parallel schaltet und zu einer vollwertigen 8-Bit-CPU verbindet? Der MC14500 war ein 1-Bit Industrial Control Unit (ICU) von Motorola aus dem Jahr 1977 — mit nur ~500 Transistoren einer der simpelsten Prozessoren, die je produziert wurden. Seine Architektur ist so minimal, dass man ihn aus wenigen 74er-Logik-ICs nachbauen kann.

Das Ergebnis wäre ein selbst entworfener 8-Bit-Prozessor mit eigenem Befehlssatz, konzeptionell verwandt mit den AMD 2901 Bit-Slice-Systemen (wie sie in der PDP-11/60 zum Einsatz kamen), aber deutlich einfacher aufgebaut und aus heute noch verfügbaren Bauteilen realisierbar.


## Hintergrund: Der MC14500 im Original

- **Architektur:** 1-Bit-Datenbus, 16 Instruktionen, reine Logic Unit (AND, OR, XOR, NOT, etc.)
- **Takt:** 1 MHz bei 5V, bis 4 MHz bei 15V
- **Besonderheit:** Kein integrierter Programmzähler — dieser wird extern realisiert, was die Architektur extrem modular macht
- **Transistorcount:** ~500 (zum Vergleich: ein 6502 hat ~3.500, ein 68000 hat ~68.000)
- **Verfügbarkeit:** Abgekündigt, aber NOS-Bestände noch über eBay/Broker erhältlich. Für dieses Projekt ohnehin irrelevant, da die Slices als Klone aus 74er-Logik aufgebaut werden.


## Architekturkonzept

### Grundprinzip: SIMD mit Carry-Chain

Acht MC14500-Klone arbeiten im Lockstep an einem gemeinsamen Programmzähler. Alle Slices empfangen denselben Opcode und dieselbe Speicheradresse, operieren aber jeweils auf ihrem eigenen Daten-Bit (Bit 0 bis Bit 7). Für logische Operationen (AND, OR, XOR) funktioniert das sofort — kein Übertrag nötig.

Für Arithmetik (Addition, Subtraktion) wird eine Carry-Chain zwischen den Slices ergänzt: Der Carry-Out von Slice N geht als Carry-In an Slice N+1.

```
           Gemeinsamer Opcode + Adresse (aus Mikroprogramm-ROM)
           ┃         ┃         ┃         ┃
      ┌────▼───┐┌────▼───┐┌────▼───┐┌────▼───┐
      │Slice 0 ││Slice 1 ││Slice 2 ││  ....  │ ... bis Slice 7
      │ (Bit 0)││ (Bit 1)││ (Bit 2)││        │
      └──┬──┬──┘└──┬──┬──┘└──┬──┬──┘└──┬──┬──┘
    Data │  │Cout   │  │Cout  │  │Cout  │  │
    Bit  │  └──►Cin │  └──►Cin│  └──►Cin│  │
         ▼          ▼         ▼         ▼
      ┌──────────────────────────────────────┐
      │         8-Bit Datenbus (D0–D7)       │
      └──────────────────────────────────────┘
```

### Carry-Erzeugung

Der Original-MC14500 hat keinen Carry-Ein-/Ausgang. In den 74er-Klonen wird dieser ergänzt. Die externe Carry-Logik pro Slice benötigt minimal:

- **Full Adder Carry:** `Cout = (A AND B) OR (A AND Cin) OR (B AND Cin)`
- Umsetzbar mit einem 74LS08 (AND) und 74LS32 (OR) für je 2 Slices
- Alternativ: 2x 74LS283 (4-Bit Full Adder) als fertige Carry-Chain für alle 8 Bit

### Erweiterung des Befehlssatzes

Da der Opcode im Mikroprogramm-ROM definiert wird, kann der Befehlssatz frei gestaltet werden. Mögliche Ergänzungen gegenüber dem Original-MC14500:

- **ADD, SUB** (über die Carry-Chain)
- **Shift/Rotate** (Daten von Slice N an Slice N±1 weiterreichen)
- **Compare** (Subtraktion ohne Ergebnis-Speicherung, nur Flags setzen)
- **Bedingte Sprünge** (Carry-Flag oder Zero-Flag steuern den Programmzähler)

Dies ist einer der größten Vorteile gegenüber einer fertigen CPU: Der Befehlssatz wird genau auf die eigenen Bedürfnisse zugeschnitten.


## Hardware-Design

### CPU-Kern (pro Slice, ca. 3–4 ICs)

Jeder 1-Bit-Slice besteht aus:

- **Logic Unit:** 1-Bit-ALU aus NAND/NOR-Gattern (1–2 ICs, z.B. 74HCT00, 74HCT02)
- **Result Register:** D-Flip-Flop (Teil eines 74HCT74)
- **Carry-Logik:** Anteil an 74HCT08/74HCT32 oder 74HCT283
- **Input/Output Enable Flags:** Anteil an weiterem 74HCT74

Bei 8 Slices: **ca. 25–35 ICs** für den reinen CPU-Kern.

### Programmsteuerung (5–8 ICs)

- **Programmzähler:** 2x 74HCT161 (4-Bit-Zähler, kaskadiert für 8–12 Bit Adressraum)
- **Mikroprogramm-ROM:** 2–3 EPROMs oder EEPROMs (z.B. 28C256), je nach Mikrowortbreite
  - Geschätzte Mikrowortbreite: 16–24 Bit (Opcode + Speicheradresse + Steuersignale)
- **Pipeline-Register:** 1x 74HCT574 (optional, aber empfohlen — versteckt die ROM-Latenz und verdoppelt nahezu den Durchsatz; vgl. PDP-11/60 Technik)
- **Sprunglogik:** 1–2 ICs für bedingte Verzweigungen (Flags direkt in Adressberechnung einspeisen)

### Arbeitsspeicher (2–3 ICs)

Der elegante Trick: Da alle 8 Slices synchron dieselbe Adresse ansprechen, kann ein einzelner Standard-8-Bit-SRAM verwendet werden.

- **SRAM:** 1x 62256 (32KB) oder 6264 (8KB) — ein einziger Chip!
- **Adressdekoder:** 1x 74HCT138 (trennt RAM- von I/O-Adressraum)
- **Bus-Treiber:** 1x 74HCT245 (falls nötig für Richtungsumschaltung)

Die 8 Datenausgänge der Slices gehen direkt auf D0–D7 des SRAM. Von der Speicherseite aus betrachtet verhält sich das System wie ein ganz normaler 8-Bit-Computer.

### Peripherie (5–8 ICs)

**Serielle Schnittstelle (UART):**
- Pragmatisch: 1x 16550 UART oder 6850 ACIA — 8-Bit-Dateninterface passt direkt auf die 8 Slices
- Puristisch: Bit-Banging im Mikrocode (langsamer, aber kein Extra-Chip nötig)

**Massenspeicher:**
- CompactFlash im True-IDE 8-Bit-Modus
- Benötigt: 3 Adressleitungen, 8 Datenleitungen, wenige Steuersignale
- Glue-Logic: 1–2 ICs (74HCT-Gatter)

**Weitere I/O:**
- GPIO: 74HCT574 (Output-Latch) + 74HCT244 (Input-Buffer)
- SPI: Einfach im Mikrocode implementierbar (Bit-Banging auf GPIO-Pins)
- Timer: 1x NE555 oder ein Zähler-IC als Interrupt-Quelle

### Taktung und Reset (2 ICs)

- **Oszillator:** Quarzoszillator-Modul (kein diskreter Quarz nötig)
- **Reset-IC:** MAX693 oder ähnlich für sauberes Power-On-Reset

### Erwartete Taktrate

- Mit 74HCT-Serie: **15–25 MHz** Mikrotakt realistisch
- Mit 74AC-Serie: **30–50 MHz** möglich
- Der kritische Pfad ist kurz: 1-Bit-ALU + Carry-Chain + Register-Setup
- Effektive Leistung (geschätzt): Vergleichbar mit einem 6502 bei 2–5 MHz, abhängig von Mikrowort-Breite und Pipeline-Stufe


## Gesamtstückliste (Schätzung)

| Baugruppe             | ICs (ca.) | Bemerkung                              |
|----------------------|-----------|----------------------------------------|
| CPU-Kern (8 Slices)  | 25–35     | Inkl. Carry-Chain                      |
| Programmsteuerung    | 5–8       | Zähler, EPROMs, Pipeline               |
| Arbeitsspeicher      | 2–3       | SRAM + Dekoder                         |
| UART                 | 1–2       | 16550/6850 + Glue                      |
| CompactFlash-IF      | 2–3       | Glue-Logic für IDE                     |
| GPIO / sonstige I/O  | 2–4       | Latches, Buffer                        |
| Takt + Reset         | 2         |                                        |
| **Gesamt**           | **~45–55**| Machbar auf 1–2 Europlatinen           |

Alle verwendeten ICs sind Standard-74HCT/74AC-Logik und gängige Speicher-/Peripherie-Chips, die bei den üblichen Distributoren (Mouser, Digikey, Reichelt) problemlos erhältlich sind.


## Variante B: CPLD-Version (~10–12 ICs)

Die diskrete Variante mit 45–55 ICs hat maximalen Lernwert, ist aber ein großes Layout-Projekt. Eine CPLD-basierte Variante reduziert die Chipcount drastisch, ohne die Kernidee zu opfern: Man entwirft die CPU-Logik weiterhin selbst — nur eben in Verilog/VHDL statt auf Lochraster.

### Warum CPLD und nicht FPGA?

Ein CPLD ist konzeptionell näher an 74er-Logik als ein FPGA:

- **Nicht-flüchtig:** Die Konfiguration ist im Chip gespeichert. Strom an → läuft. Kein Bitstream-Laden, kein Boot-ROM, kein "Warten bis der FPGA konfiguriert ist". Exakt wie ein 74er-IC.
- **Deterministische Laufzeiten:** Die Signallaufzeiten sind vorhersagbar und gleichmäßig, ähnlich wie bei diskreter Logik. Bei FPGAs hängen die Laufzeiten stark vom Place-and-Route ab.
- **Einfachere Toolchain:** Kein Synthesizer für Block-RAM, keine Clock-Manager, keine Constraints-Dateien. Kombinatorische und sequentielle Logik, mehr nicht.
- **5V-tolerant:** Einige CPLDs (ATF1508, EPM7128) arbeiten direkt mit 5V-Logik — kein Level-Shifting zur restlichen Peripherie nötig.

### Empfohlener CPLD: Microchip ATF1508AS

- 128 Makrozellen — reicht locker für die komplette 8-Bit-CPU inkl. Carry-Chain, Flags und Steuerlogik
- 5V-Betrieb, direkt kompatibel mit SRAM, UART und CF-Interface
- PLCC-84-Gehäuse, gut lötbar (kein BGA)
- Programmierbar mit preiswerten Programmern (z.B. ATDH1150USB oder TL866)
- Bei Mouser/Digikey regulär auf Lager, nicht abgekündigt
- Alternativ: Altera/Intel EPM7128S (gleichwertig, PLCC-84, ebenfalls noch lieferbar)

### Was geht in den CPLD?

Der CPLD ersetzt die gesamte diskrete CPU-Logik:

- Alle 8 ALU-Slices inkl. Carry-Chain
- Result-Register und Flags (Carry, Zero)
- Instruction Decoder
- Programmzähler (12 Bit → 4096 Adressen)
- Sprunglogik (bedingt/unbedingt)
- Adressdekoder für Speicher und I/O
- Bus-Steuerung (Read/Write-Signale, Richtungsumschaltung)

Im HDL-Code sind die acht Slices weiterhin als instanziierte Module sichtbar — man *sieht* die Bit-Slice-Architektur im Code, auch wenn sie physisch in einem Chip steckt.

### Stückliste CPLD-Variante

| Baugruppe             | ICs  | Typ                          |
|----------------------|------|------------------------------|
| CPU (komplett!)      | 1    | ATF1508AS (PLCC-84)          |
| Mikroprogramm-ROM   | 2    | 28C256 EEPROM (parallel)     |
| Pipeline-Register    | 1    | 74HCT574 (optional)          |
| Arbeitsspeicher      | 1    | 62256 SRAM (32KB)            |
| UART                 | 1    | 16550 oder 6850 ACIA         |
| CompactFlash-Slot    | 1    | CF-Adapter (kein IC nötig)   |
| Oszillator           | 1    | Quarzoszillator-Modul        |
| Reset                | 1    | MAX693 oder DS1233           |
| Spannungsregler      | 1    | 7805 o.ä.                    |
| **Gesamt**           |**~10**| **Passt auf eine Platine 100x80mm** |

### Optionale Erweiterung: Mikroprogramm-ROM ebenfalls im CPLD

Bei 128 Makrozellen bleibt nach der CPU-Logik vermutlich wenig Platz für den Mikrocode-Speicher. Aber: Wenn man einen zweiten ATF1508 oder einen größeren CPLD (z.B. EPM7256) verwendet, kann der Mikrocode als Lookup-Table direkt im CPLD liegen. Damit fallen auch die EPROMs weg und man braucht keinen EPROM-Programmer mehr. Die Stückliste schrumpft auf 7–8 ICs.

### Vorteile der CPLD-Variante

- **Iteratives Design:** Befehlssatz ändern = CPLD neu programmieren. Kein Umlöten, kein neues EPROM brennen.
- **Debugging:** Die internen Signale können über freie CPLD-Pins nach außen geführt werden — wie ein eingebauter Logikanalysator.
- **Reproduzierbar:** Ein KiCad-Projekt mit 10 ICs ist realistisch als Open-Source-Kit verteilbar.
- **Erweiterbar:** Freie CPLD-Pins können für SPI, I²C oder zusätzliche Timer genutzt werden, ohne Extra-ICs.

### Geschätzte Taktrate

Der ATF1508 hat Pin-to-Pin-Delays von ca. 7,5 ns. Da der kritische Pfad (8-Bit Carry-Chain durch die ALU) komplett innerhalb des CPLD liegt und nicht über Platinen-Traces gehen muss, sind **30–50 MHz** realistisch. Effektive Leistung: vergleichbar mit einem 6502 bei **4–8 MHz**, je nach Befehlssatz-Effizienz.

### Platinengröße

Mit nur 10 ICs (alle in Through-Hole/PLCC), einem CF-Slot, ein paar LEDs für Status, und Pfostenstiften für Serial + GPIO passt das komplette System auf eine **einzelne Platine im Format 100x80mm** — kleiner als eine Postkarte. Oder großzügiger auf Europlatinen-Format (160x100mm) mit Platz für Beschriftung, Debug-Header und vielleicht ein kleines OLED-Display.


## Vergleich der Varianten

| Eigenschaft              | Diskret (74er)    | CPLD              |
|--------------------------|-------------------|-------------------|
| IC-Count                 | 45–55             | ~10               |
| Platinen                 | 1–2 Europlatinen  | 1 kleine Platine  |
| Lernwert Hardware        | Maximal           | Hoch (HDL-Ebene)  |
| Lernwert CPU-Design      | Sehr hoch         | Sehr hoch         |
| Iterationsgeschwindigkeit| Langsam (umlöten) | Schnell (flashen)  |
| Debugging                | Oszilloskop       | Interne Signale    |
| Max. Takt                | 15–25 MHz (HCT)   | 30–50 MHz         |
| Eff. Leistung (≈6502)   | ~2–5 MHz          | ~4–8 MHz          |
| Retro-Faktor             | ★★★★★            | ★★★☆☆            |
| Machbarkeit Solo         | Ambitioniert       | Realistisch        |
| Reproduzierbarkeit       | Aufwendig          | Einfach (Kit)      |

### Empfohlener Weg

**Simulation → CPLD-Prototyp → optional diskret:**

1. Architektur in Logisim / Digital simulieren und den Befehlssatz entwerfen
2. HDL-Code schreiben und im CPLD umsetzen — lauffähiges System in überschaubarer Zeit
3. Wer den maximalen Retro-Faktor will, kann die funktionierende HDL-Beschreibung danach als Bauplan für die diskrete 74er-Version verwenden


## Software

### Entwicklungsumgebung

- **Mikrocode-Assembler:** Eigenes Tool (Python-Skript reicht), das Mnemonics in ROM-Images für die Mikroprogramm-EPROMs übersetzt
- **Makro-Assembler:** Baut auf dem Mikrocode auf und definiert die "sichtbaren" Maschinenbefehle
- **Simulator:** Empfehlenswert vor dem Hardware-Aufbau — die Architektur lässt sich gut in Logisim oder Digital simulieren

### Erste Software-Ziele

1. **LED-Blinker** — das "Hello World" der Hardware-Welt
2. **Memory Monitor** — Speicher über UART lesen/schreiben, Programme laden
3. **Einfacher Rechner** — demonstriert die Arithmetik-Fähigkeiten
4. **Tiny BASIC** — ein BASIC-Interpreter auf einer CPU aus acht 1-Bit-Prozessoren wäre ein Statement

### Fortgeschrittene Ziele

- **Forth** — passt hervorragend auf minimalistische Architekturen
- **Einfaches Dateisystem** auf CompactFlash (FAT12 oder eigenes Format)
- **Bootloader** der Programme von CF in RAM lädt


## Warum dieses Projekt?

### Lernwert

Man versteht *jedes einzelne Gatter* in der CPU. Es gibt keine Black Box, keinen Mikrocode den jemand anderes geschrieben hat. Vom Carry-Bit bis zum Interrupt — alles ist selbst entworfen und nachvollziehbar.

### Historische Einordnung

Das Projekt verbindet mehrere Konzepte der Computergeschichte:
- **Bit-Slicing** (AMD 2901, genutzt in PDP-11/60, diverse Mainframes)
- **Mikroprogrammierung** (Maurice Wilkes, 1951 — die Idee, CPUs per Software zu definieren)
- **SIMD-Parallelismus** (Connection Machine, moderne GPUs)
- **Minimale Prozessoren** (MC14500, PDP-14, Industriesteuerungen)

### Gemeinschaftsprojekt

Die Architektur eignet sich hervorragend als Open-Source-Hardware-Projekt:
- Modularer Aufbau (einzelne Slices können separat getestet werden)
- Schrittweiser Aufbau möglich (erst 1 Bit, dann 2, dann 4, dann 8)
- Der Befehlssatz kann von der Community diskutiert und optimiert werden
- KiCad-Schaltpläne und Mikrocode auf GitHub

### Verfügbarkeit

Im Gegensatz zu Bit-Slice-Projekten mit abgekündigten AMD 2901 besteht dieses System komplett aus Standard-Logik-ICs die seit Jahrzehnten produziert werden und auf absehbare Zeit verfügbar bleiben.


## Verwandte Projekte und Ressourcen

- **Usagi Electric (YouTube):** Hat einen MC14500-basierten Röhrencomputer (UE-1, 192 Röhren) und eine Mini-Version (UE-0.1, 24 Röhren) gebaut
- **PLC14500-Nano:** Fertige Trainer-Platine mit echtem MC14500, Bausatz auf Tindie erhältlich
- **MC14500B Handbook (Motorola, 1977):** Original-Dokumentation, online verfügbar auf bitsavers.org
- **Hackaday.io "One Bit CPUs":** Diverse Klon- und Reimplementierungsprojekte
- **"PLC14500 Programmers' Guide" (Nicola Cimmino):** Buch über 1-Bit-Programmierung in den 2020ern
- **Ben Eater (YouTube):** 8-Bit Breadboard CPU — ähnlicher Lern-Ansatz, aber mit klassischer Architektur statt Bit-Slice


## Lizenz

Dieses Konzeptdokument ist frei verwendbar. Wer das Projekt aufgreift, wird ermutigt, es unter einer offenen Hardware-Lizenz (z.B. CERN OHL oder TAPR OHL) zu veröffentlichen.

---

*Entstanden aus einem Gedankenspiel über Multiprozessor-Systeme, das bei der Frage begann, ob man mit einem 6502 einen Multi-CPU-Computer bauen könnte — und über den Motorola 68000, PDP-11 Bit-Slice-Systeme und Röhrencomputer schließlich hier landete.*
