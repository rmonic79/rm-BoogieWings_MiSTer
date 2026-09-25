# rm_BoogieWings_MiSTer

FPGA core for **Boogie Wings** (also known as **The Great Ragtime Show**,
Data East Corporation, 1992) targeting the
[MiSTer FPGA](https://github.com/MiSTer-devel) platform (Terasic DE10-Nano).

Boogie Wings runs on the **Data East DE-0297 board** — a horizontal arcade
hardware with a 68000 main CPU, HuC6280 sound CPU, two DECO16IC tilemap
chips (four scrolling playfields), a custom sprite generator, the DECO ACE
alpha-blend mixer, DECO104 protection, and YM2151 + dual OKI M6295 audio.

This core reimplements the hardware in SystemVerilog from MAME references
and hardware observation.

---

# The `rm` version

*This section is the same in every `rm` core: it explains what the line is and
what it adds. Skip it if you already know.*

**`rm` cores are my own builds, published outside the MiSTer-devel tree.** They
are not a fork of the emulation: the core is the same one I contribute
upstream, plus two things the official tree cannot host, because both require
editing the `sys/` framework and MiSTer-devel does not take those changes.

### 1. CRT geometry that leaves HDMI alone

**CRT Adjust** (H-Size, H-Position, V-Shift) and **CRT V-Size** let you align
and size the picture on a 15 kHz tube from the OSD, with the sync left native
so the screen never loses lock, and without duplicating or dropping a single
line.

The point of the whole thing is *where* they sit: **sys-side**, in the analog
chain between the scanline stage and the OSD. The scaler taps the video
**before** that point, so **HDMI stays bit-identical while you adjust the
CRT** — you can align a tube without touching what a capture card or a
streaming setup sees. Putting the same modules inside the core would drag HDMI
along with every correction, which defeats the purpose.

V-Size offers two modes: **PVM** (retimes the lines — perfect on broadcast
monitors with a wide lock range) and **Cabinet** (native timing, photometric —
the sync stays rock-steady on arcade chassis with tight AFC).

### 2. Pause overlay

Logo, supporters list and scrolling credits, shown while the game is paused.

### Naming

| | |
|---|---|
| repository / folder | `rm_<Title>_MiSTer` |
| Quartus project and RBF | `rm<Title>` |
| MRA files | `rm <Title> (…).mra` |

The `rm` RBF has a **different file name** from the official core, so the two
can sit on the same SD card without overwriting each other, and you choose
which one to launch from the MRA.

### What the MiSTer-devel version has instead

Everything else, identically: savestates, audio work, video fixes, hardware
accuracy. What it does **not** have is the CRT geometry controls and the pause
overlay — the two items above.

---

## About the game

**Boogie Wings** (*The Great Ragtime Show* in Japan) is a horizontally
scrolling shoot-'em-up with a twist: you pilot a WWI-era biplane, but you
can bail out at any moment and drop down to fight on foot, grabbing a
grappling hook to swing across the stage, hijack enemy vehicles, and hurl
objects at your foes. The mix of aerial and ground combat, the destructible
scenery and the hand-drawn cartoon art make it one of Data East's most
distinctive action games. The DE-0297 board pushes four scrolling
playfields blended through the DECO ACE mixer, giving the game its layered,
colourful look.

## Status

**Current version: 1.8** (September 2026).

The core runs the full game with audio, inputs and savestates, tested on
real MiSTer hardware.

**New in 1.8**
- **CRT Adjust and CRT V-Size, sys-side**: H-Size, H-Position and V-Shift plus
  vertical sizing in **PVM** and **Cabinet** modes, with **HDMI left
  bit-identical** while you adjust the tube (see *The `rm` version* above).
  This replaces the previous core-side H-Size, which dragged HDMI along with it.
- **Sprites covered by smoke no longer disappear.** The second sprite chip kept
  a single pixel per position in its line buffer, so a translucent pixel
  overwrote the opaque sprite underneath and then blended with the *background*
  instead of with the object — power-ups and set pieces vanished under smoke and
  explosions. The chip now carries an opaque and a translucent layer, so both
  pixels reach the mixer. Measured on real scenes captured from hardware: 21224
  object pixels were being replaced, now none, with the behaviour outside the
  overlap bit-identical.
- **Flip screen now flips the sprites too.** The coordinates were being mirrored
  twice, once in the top level and once inside the sprite renderer, so the
  sprites stayed upright while everything else turned over.
- **32 savestate slots** (4 regions × 8 sub-slots), ported from Night Slashers.
- **Audio**: 4× OKI interpolation with a flat-band FIR, mix EQ, inter-chip
  balance taken from MAME, and a 10-bit mixer.
- **Per-channel gains in the OSD**, with clearer English labels: FM (YM2151),
  OKI0 (Voice/SFX), OKI1 (Drums) and a Presence (Highs) control.
- **Two DIP options that showed up blank** in the OSD menu (Continue Coin and
  Stage Reset) now fit and display correctly.
- **Pause overlay**: supporters list updated.
- **Timing**: the protection table → rambank chain was split, taking the core
  from −0.106 to a positive slack without hiding anything in the SDC.
- **Documentation**: the board's priority PROM (`kj-00.15n`, the one MAME loads
  and marks *"not used"*) is decoded in [docs/](docs/) — input mapping proved
  with zero exceptions, and the places where MAME's reimplementation departs
  from the table.

**Milestones reached**
- Full playthrough with accurate video, audio and controls
- The DE102 encrypted 68000 opcodes and the DECO56 tile scramble are
  decrypted on board during ROM download — no pre-decrypted ROMs needed
- DECO104 protection (I/O + data scramble) reproduced from MAME
- MAME-accurate DECO16IC tilemaps (per-row / per-column scroll) and the
  DECO ACE alpha-blend + fade mixer, including the simultaneous row+column
  scroll used by the Data East intro logo dissolve
- Savestate (save / restore) ported from the Taito F2 core, including the
  HuC6280 / YM2151 / OKI internal state
- Native 57.8 Hz refresh with an optional 60 Hz mode
- Hardened OKI audio path against DDR arbitration pressure (no starvation /
  glitches when the fitter reshuffles the design)
- CRT Adjust and CRT V-Size implemented sys-side, with HDMI left untouched
- Priority PROM `kj-00.15n` decoded from the table itself (see `docs/`)

**Roadmap**
- Wire the board's priority PROM into the mixer, replacing the layer order
  MAME has been carrying unverified since 2007
- Further audio and video accuracy polish
- Additional savestate hardening across edge cases
- More regional ROM sets as they are verified

**Features**
- 68000 main CPU (FX68K core) with DECO104 protection (I/O + scramble)
- HuC6280 sound CPU @ 8.055 MHz
- Two DECO16IC tilemap chips: BG0/BG1 (chip 0) + FG0/FG1 (chip 1),
  16×16 and 8×8 tiles, per-row and per-column scroll — MAME-accurate
- DECO ACE alpha-blend / fade mixer for layer composition
- Sprite renderer with priority, flip, 16×16 4bpp tiles, buffered sprite RAM
- Audio: YM2151 (OPM, JT51) + two OKI M6295 ADPCM (JT6295)
- Tile ROM streaming through a 4-bank SDRAM (JTFRAME SDRAM64)
- Sprite ROM and OKI ADPCM ROM backed by DDR3
- VBlank-synchronized pause (frame-aligned, no race conditions)
- **CRT Adjust** (H-Size, H-Position, V-Shift) and **CRT V-Size** (PVM /
  Cabinet), sys-side — HDMI stays bit-identical while you adjust — see note below
- **Per-channel audio gains** in the OSD: FM (YM2151), OKI0 (Voice/SFX),
  OKI1 (Drums), plus a Presence (Highs) control
- MiSTer OSD with video and DIP options
- Pause overlay with logo + supporters scroll
- Savestate (save/restore) infrastructure ported from the Taito F2 core

### A note on how the CRT controls work

The picture is not rescaled: every source pixel is emitted for an **integer**
number of pixel-clock periods through a line buffer, so H-Size is free of
shimmering and of scaling artifacts, and the content is byte-exact. The
horizontal sync is left **native** — the CRT keeps its lock while you resize
and slide the image, which is why nothing rolls or tears during adjustment.

V-Size does not duplicate or drop lines either: it retimes the line period and
the line count per frame so their product stays exactly one frame, spreading
the same unique lines further apart. In **Cabinet** mode it instead keeps the
native timing and redistributes light between adjacent lines in linear gamma,
so the sync never moves at all — made for arcade chassis with a tight AFC.

Both stages sit **sys-side**, after the scaler tap: HDMI is bit-identical
throughout. This is what the `rm` line exists for (see the top of this file).

**ROM sets supported**
- Boogie Wings (`boogwing`, Euro v1.5, 92.12.07) — parent
- Boogie Wings (`boogwinga`, Asia v1.5, 92.12.07)
- Boogie Wings (`boogwingu`, USA v1.7, 92.12.14)
- The Great Ragtime Show (`ragtime`, Japan v1.5, 92.12.07)
- The Great Ragtime Show (`ragtimea`, Japan v1.3, 92.11.26)

## Screenshots

| | |
|---|---|
| ![Title](docs/bw_Logo.png) | ![Data East](docs/bw_DE_Logo.png) |
| Title screen | Data East |
| ![Gameplay 1](docs/bw_Gameplay_1.png) | ![Gameplay 2](docs/bw_Gameplay_2.png) |
| Gameplay | Gameplay |
| ![Tutorial](docs/bw_tutorial_1.png) | ![High scores](docs/bw_Score.png) |
| Tutorial | High scores |

## Hardware emulated

| Component        | Spec                                                |
|------------------|-----------------------------------------------------|
| Main CPU         | M68000 @ 14 MHz (DE102 encrypted opcodes)           |
| Sound CPU        | HuC6280 @ 8.055 MHz                                  |
| Sound chip 1     | Yamaha YM2151 OPM (jt51)                             |
| Sound chip 2     | OKI M6295 (jt6295) ×2 — 1 MHz and 2 MHz             |
| Tilemaps         | DECO16IC ×2 (four playfields, 16×16 / 8×8)          |
| Sprites          | DECO_SPRITE ×2 (alpha-blend)                         |
| Palette / mixer  | DECO ACE (palette + alpha-blend + fade)             |
| I/O + protection | DECO104                                             |

## Hardware requirements

- Terasic DE10-Nano
- MiSTer I/O board (recommended)
- SDRAM module (32 MB or 64 MB)
- DDR3 memory (built into DE10-Nano, used for sprite ROM and OKI ADPCM ROM)
- Works on HDMI displays and on CRTs via the analog video output

## Building from source

Requires Quartus Prime 17.0 (free Lite Edition).

```
Open rmBoogieWings.qpf in Quartus → Processing → Start Compilation
```

Output bitstream is generated in `output_files/rmBoogieWings.rbf`.

## Running on MiSTer

The [releases/](releases/) folder contains the parent MRA and a
prebuilt RBF; regional clone MRAs are in
[releases/_alternatives/](releases/_alternatives/):

- `rm Boogie Wings (Euro v1.5, 92.12.07).mra` — parent MRA
- `rmBoogieWings_YYYYMMDD.rbf` — prebuilt bitstream
- `_alternatives/rm Boogie Wings (Asia v1.5, 92.12.07).mra` / `(USA v1.7, 92.12.14).mra` /
  `rm The Great Ragtime Show (Japan v1.3 / v1.5).mra` — regional clones

Note: `v1.5` in those names is the **ROM set** revision, not the core version.

Steps:

1. Copy the `.rbf` to `_Arcade/cores/` on the MiSTer SD card, renamed to
   `rmBoogieWings.rbf` — that is the name the MRA looks for. The official
   core keeps its own name, so both can sit there together.
2. Copy the `.mra` file(s) to `_Arcade/` on the MiSTer SD card.
3. Provide your legally-owned `boogwing.zip` (or regional variant) where
   the MRA expects it (usually in `games/mame/`).

**ROMs are NOT included in this repository.** You must provide them yourself.

## Repository layout

```
rm_BoogieWings_MiSTer/
├── rtl/
│   ├── boogwings/   Boogie Wings-specific core RTL
│   ├── common/      shared logic: DECO104, DECO ACE glue, savestate, bridges
│   ├── HUC6280/     HuC6280 sound CPU
│   ├── fx68k/       FX68K M68000 cycle-accurate core
│   ├── jt51/        YM2151 FM synth
│   ├── jt6295/      OKI M6295 ADPCM
│   ├── jtframe/     JTFRAME framework modules
│   ├── pll/         Clock PLL
│   └── sdram.sv     SDRAM controller (Sorgelig)
├── sys/             MiSTer framework (Sorgelig / MiSTer-devel)
├── logo/            Pause overlay assets (font, logo, supporter list)
├── docs/            In-game screenshots
├── releases/          Parent MRA + regional clones + prebuilt RBF
├── rmBoogieWings.qpf  Quartus project
├── rmBoogieWings.qsf  Quartus assignments
├── Template.sv      Top-level wrapper
├── Template.sdc     Timing constraints
├── files.qip        HDL file list
├── build_id.v       Build version stamp
└── README.md        This file
```

## Acknowledgements

- **Jose Tejada** ([@jotego](https://github.com/jotego)) for JT51 (YM2151),
  JT6295 (OKI M6295) and the JTFRAME framework (including SDRAM64).
- **Sergey Dvodnenko** ([@srg320](https://github.com/srg320)), with **Sorgelig**
  and **David Shadoff**, for the HuC6280 core (from the MiSTer TurboGrafx-16 /
  PC Engine core); original design by **Gregory Estrade** (FPGAPCE).
- **Jorge Cwik** ([ijor](https://github.com/ijor)) for the **FX68K**
  cycle-accurate M68000 core.
- **Martin Donlon** ([wickerwaka](https://github.com/wickerwaka)) for the
  savestate infrastructure, ported from the Arcade-TaitoF2 core.
- The **MAMEDev team** for the invaluable reference on the DECO16IC tilemaps,
  DECO104 protection, DECO ACE mixer, memory maps and timing.
- **Sorgelig** and the **MiSTer-devel team** for the framework, SDRAM
  controller and Template.
- **Andrea Bogazzi** ([@asturur](https://github.com/asturur)) for help with the
  Analog H-Size implementation.

## Support this project

If you enjoy this core and want to support its development:

- [Ko-fi](https://ko-fi.com/ibecerivideoludici) — one-time support
- [Patreon](https://www.patreon.com/IBeceriVideoludici) — monthly support
- [PayPal](https://www.paypal.me/IBeceriVideoludici) — one-time donation

## Follow

- [GitHub](https://github.com/rmonic79)
- [Twitch](https://twitch.tv/ibecerivideoludici) — live streams
- [YouTube](https://www.youtube.com/c/IBeceriVideoludici) — playlists and videos
- [X / Twitter](https://x.com/rmonic79)

## License

The RTL source code in this repository is provided as-is for educational
and preservation purposes under **GNU GPL v3 or later**. Original ROM data
is not included; users must provide their own legally obtained copies.

Original *Boogie Wings* / *The Great Ragtime Show* arcade hardware
© Data East Corporation, 1992.
