# Authors and Credits

## BoogieWings_MiSTer core

**Author**: Umberto Parisi ([rmonic79](https://github.com/rmonic79))

The original RTL source files for the Boogie Wings / The Great Ragtime Show
specific logic (under `rtl/boogwings/` and the project wrapper `Template.sv`)
are copyright Umberto Parisi and distributed under GNU GPL v3 or later.

## Third-party components

This core builds on top of excellent open-source projects. All third-party
sources retain their original copyright and license. The core as a whole
is distributed under **GNU GPL v3 or later** to stay compatible with the
most restrictive upstream (JTFRAME / JTCORES).

| Component | Author | Project | License |
|-----------|--------|---------|---------|
| **FX68K** — M68000 cycle-accurate core | Jorge Cwik | [ijor/fx68k](https://github.com/ijor/fx68k) | GPL-3 |
| **HUC6280** — Hudson HuC6280 (audio CPU) core | Sergey Dvodnenko ([@srg320](https://github.com/srg320)), with Sorgelig and David Shadoff; original design by Gregory Estrade (FPGAPCE) — from the MiSTer TurboGrafx-16 / PC Engine core | [MiSTer-devel/TurboGrafx16_MiSTer](https://github.com/MiSTer-devel/TurboGrafx16_MiSTer) | GPL-3 |
| **JT51** — Yamaha YM2151 (OPM) FM synthesizer | Jose Tejada ([@topapate](https://twitter.com/topapate)) | [jotego/jt51](https://github.com/jotego/jt51) | GPL-3 |
| **JT6295** — OKI MSM6295 ADPCM decoder | Jose Tejada | [jotego/jt6295](https://github.com/jotego/jt6295) | GPL-3 |
| **JTFRAME** — framework, clock enables, filters, mixer, shift registers, SDRAM64 | Jose Tejada | [jotego/jtframe](https://github.com/jotego/jtframe) | GPL-3 |
| **Savestate infrastructure** — ssbus, memory_stream, auto_save_adaptor, ram adaptors | Martin Donlon ([wickerwaka](https://github.com/wickerwaka)) | [wickerwaka/Arcade-TaitoF2_MiSTer](https://github.com/wickerwaka/Arcade-TaitoF2_MiSTer) | GPL-3 |
| **JTFRAME SDRAM64** — SDRAM controller (4-bank) | Jose Tejada | [jotego/jtframe](https://github.com/jotego/jtframe) | GPL-3 |
| **MAME** — reference for DECO16IC tilemap, DECO104 protection, DECO ACE, memory maps, timing | MAMEDev team | [mamedev/mame](https://github.com/mamedev/mame) | GPL-2+ |
| **sys/ framework** — MiSTer HPS/IO, OSD, video scaler, audio | Sorgelig / MiSTer-devel | [MiSTer-devel/Main_MiSTer](https://github.com/MiSTer-devel/Main_MiSTer) | GPL-3 |

## Reference

- **Boogie Wings / The Great Ragtime Show arcade hardware** — Data East
  Corporation, 1992 (DE-0297-3 board). This FPGA core is a reimplementation
  from hardware documentation, MAME source code, and observation of real
  hardware behavior. ROMs are **not** included and must be provided by the user.
- **MAME project** — invaluable reference for memory maps, timing, the
  DECO16IC tilemap chips, DECO104 protection, and the DECO ACE mixer.
  [mamedev/mame](https://github.com/mamedev/mame)
