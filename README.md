# evcharge

Version 1.0

Turns a folder of EV charging invoices (PDF) into a monthly expense pack: a spreadsheet, and a
single PDF with a summary table followed by every invoice.

Built for the common public charging networks operating in Australia. It assumes Australian
conventions throughout: amounts in AUD, 10% GST split out of the inc-GST total, and day-first
dates (DD/MM/YYYY). Invoices from other countries may parse, but the GST columns will be wrong.

Standalone macOS command-line tool with no third-party dependencies (see
[Other platforms](#other-platforms-linux-windows) for Linux and Windows). It links only frameworks
that ship with macOS: PDFKit for text extraction and merging, Vision for OCR of scanned
invoices, CoreGraphics/CoreText for the summary page, and libz for the `.xlsx` container.

Supported providers: EVX, Tesla Supercharger, Chargefox, AGL, Ampol AmpCharge, EvieCharge
(including image-only receipts via OCR), JOLT. Anything else is listed as `Unknown`.

## Download

Prebuilt binaries are attached to each [GitHub release](https://github.com/boraoku/ev-charger-bills/releases):

| Archive | For |
|---|---|
| `evcharge-1.0-macos-universal.zip` | Any Mac (recommended) |
| `evcharge-1.0-macos-arm64.zip` | Apple silicon only |
| `evcharge-1.0-macos-x86_64.zip` | Intel only |

Each archive holds the `evcharge` binary, a default `evcharge.conf`, this README and the licence. Requires
macOS 12 or later. The binaries are ad-hoc signed, not notarised, so macOS blocks a downloaded
copy at first. After unzipping, clear the quarantine flag once:

    xattr -d com.apple.quarantine evcharge

## Build

Needs the Xcode Command Line Tools (`xcode-select --install`), nothing else.

    ./build.sh

This produces `./evcharge`, a universal (Apple silicon + Intel) binary.

To produce the release archives listed above in `dist/`, run `./release.sh`. The version number
lives in `EVCHARGE_VERSION` at the top of `src/evcharge.mm`; `evcharge --version` prints it.

## Settings

`evcharge.conf` must sit in the same folder as the `evcharge` executable:

    name  = EV DRIVER
    plate = ELC CAR
    # vehicle = TESLA MODEL Y      (optional, printed before the plate)

If the file is missing, the output shows `NO NAME SET` and `NO PLATE SET`.

## Use

    ./evcharge samples             # or any folder of invoices; defaults to the current folder

For every `*.pdf` in the folder (except earlier `*_Charging_Total.pdf` results) it extracts the
provider, date, invoice number and total, sorts by date, and creates `MM-YY_Charging/` named
after the earliest invoice, containing:

- `NN_MM-YY Provider.pdf`: a numbered copy of each invoice
- `MonthYY_Charging_Total.xlsx`: the table, with GST split by formula
- `MonthYY_Charging_Total.pdf`: summary page followed by all invoices

Set `EVCHARGE_DEBUG=1` to print the text extracted from each PDF. This helps when adding a new
provider: the regex tables live near the top of `src/evcharge.mm`.

## Samples

`samples/SAMPLE_01.pdf` to `SAMPLE_06.pdf` are real invoices, one per provider. Personal details are
replaced by placeholders, and all dates moved to October 2026 so the set forms a single month.
`SAMPLE_06.pdf` is an image-only EvieCharge receipt that exercises the OCR path.

    ./evcharge samples             # creates samples/10-26_Charging/

## Other platforms (Linux, Windows)

This tool was developed and tested on macOS only. Being honest about the current state: it does
**not** build on Linux or Windows as it is, because the parts that touch PDFs, OCR and drawing call
Apple frameworks directly. The rest is plain C++17 and should carry over unchanged.

| Job | macOS (today) | Linux | Windows |
|---|---|---|---|
| PDF text extraction | PDFKit | poppler-cpp or MuPDF | PDFium or MuPDF |
| OCR of scanned invoices | Vision | Tesseract | `Windows.Media.Ocr` (built into Windows 10+) |
| Rendering a page for OCR | CoreGraphics | poppler or MuPDF | `Windows.Data.Pdf` (built in) or PDFium |
| Merging PDFs | PDFKit | qpdf or MuPDF | qpdf, PDFium or MuPDF |
| Drawing the summary page | CoreGraphics + CoreText | see note below | see note below |
| Regular expressions | `NSRegularExpression` (ICU) | ICU or `std::regex` | ICU (`icu.dll` ships with Windows 10 1903+) or `std::regex` |
| Deflate for `.xlsx` | system `libz` | system `zlib` | bundle zlib or miniz |
| Executable folder (for `evcharge.conf`) | `_NSGetExecutablePath` | `readlink("/proc/self/exe")` | `GetModuleFileNameW` |
| Date parsing | `strptime` | `strptime` | `std::get_time` (MSVC has no `strptime`) |

Unlike macOS, neither Linux nor Windows ships a library that can extract text from a PDF and
merge PDFs, so a port needs at least one PDF library. On Linux these are one package-manager
install away. On Windows, PDFium (a single DLL, BSD licensed) or MuPDF are the practical choices.

The summary page uses only Helvetica text and one line. A small hand-written PDF writer using the
standard Type 1 fonts would make that part portable on every platform with no library at all.

### Suggested approach

1. Split `src/evcharge.mm` into a portable core and a small platform layer. The core covers
   pattern matching, the `.xlsx` writer, the summary layout and file handling. The platform layer
   is an interface along the lines of `extractText`, `ocrPage`, `mergePdfs`, `executableDir`.
2. Keep `src/platform_mac.mm` as the current implementation, so macOS stays dependency-free.
3. Add `src/platform_linux.cpp` and `src/platform_windows.cpp`, built with `build.sh` on Linux,
   and with MSVC or clang-cl on Windows (for example a `build.bat` or a CMake file).
4. Check the result against `samples/`: the summary should list six invoices totalling $96.42.

Regex behaviour differs slightly between ICU and `std::regex`, so on any port check that every
provider in `samples/` still parses. The macOS build matches case-insensitively, and the
last-resort amount pattern needs `^`/`$` to anchor at line breaks.

### Contributions welcome

Pull requests that add Linux or Windows support are very welcome, as are new providers and
better patterns. Please keep the macOS build working and dependency-free, and run the samples on
every platform you touch before submitting.

## License

MIT, see [LICENSE](LICENSE).
