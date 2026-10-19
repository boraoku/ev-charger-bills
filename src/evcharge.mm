// evcharge.mm
// EV Charging Expense Processor, standalone macOS port of ev_charging_processor.py.
//
// Zero third-party dependencies. Uses only frameworks that ship with macOS:
//   PDFKit        text extraction from PDF invoices + merging PDFs
//   Vision        OCR fallback for image-only invoices (replaces tesseract/poppler)
//   CoreGraphics  drawing the summary table into a PDF (replaces reportlab)
//   CoreText      font rendering for the summary page
//   Foundation    ICU regular expressions (NSRegularExpression), file operations
//   libz          deflate for the .xlsx container (replaces openpyxl)
//
// Build: see build.sh
// Usage: evcharge [folder]      (defaults to the current directory)
//
// Driver name and plate come from evcharge.conf, located next to the executable.

#import <Foundation/Foundation.h>
#import <PDFKit/PDFKit.h>
#import <Vision/Vision.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#include <zlib.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdexcept>
#include <mach-o/dyld.h>
#include <climits>
#include <cstdlib>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>

// =============================================================================
// CONFIGURATION
// =============================================================================

static const char *EVCHARGE_VERSION    = "1.0";
static const double CFG_GST_RATE        = 0.10;
static const char *CFG_DEFAULT_PROVIDER = "Unknown";

static const char *MONTH_UPPER[] = {"JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE",
                                    "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER"};
static const char *MONTH_TITLE[] = {"January", "February", "March", "April", "May", "June",
                                    "July", "August", "September", "October", "November", "December"};

// =============================================================================
// SMALL HELPERS
// =============================================================================

static NSString *NS(const std::string &s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }
static std::string STD(NSString *s) { return s ? std::string([s UTF8String]) : std::string(); }

static void logmsg(const char *level, const std::string &msg) {
    time_t t = time(nullptr);
    struct tm lt;
    localtime_r(&t, &lt);
    char buf[16];
    strftime(buf, sizeof buf, "%H:%M:%S", &lt);
    printf("%s - %s - %s\n", buf, level, msg.c_str());
    fflush(stdout);
}
#define LOGI(x) logmsg("INFO", (x))
#define LOGW(x) logmsg("WARNING", (x))
#define LOGE(x) logmsg("ERROR", (x))

static std::string fmt(const char *f, ...) __attribute__((format(printf, 1, 2)));
static std::string fmt(const char *f, ...) {
    char buf[2048];
    va_list ap;
    va_start(ap, f);
    vsnprintf(buf, sizeof buf, f, ap);
    va_end(ap);
    return buf;
}

static std::string trim(const std::string &s) {
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return "";
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
}

static bool endsWith(const std::string &s, const std::string &suf) {
    return s.size() >= suf.size() && s.compare(s.size() - suf.size(), suf.size(), suf) == 0;
}

static std::string lower(std::string s) {
    for (auto &c : s) c = (char)tolower((unsigned char)c);
    return s;
}

static std::string basenameOf(const std::string &p) { return STD([NS(p) lastPathComponent]); }
static std::string stemOf(const std::string &p) { return STD([[NS(p) lastPathComponent] stringByDeletingPathExtension]); }

// ---- settings (evcharge.conf next to the executable) ------------------------

static const char *CONF_NAME = "evcharge.conf";

struct Settings {
    std::string name = "NO NAME SET";
    std::string plate = "NO PLATE SET";
    std::string vehicle;   // optional, e.g. "TESLA MODEL Y"

    std::string vehicleLine() const { return vehicle.empty() ? "Rego: " + plate : vehicle + ", Rego: " + plate; }
};
static Settings g_settings;

static std::string executableDir() {
    uint32_t size = 0;
    _NSGetExecutablePath(nullptr, &size);
    std::string buf(size, '\0');
    if (_NSGetExecutablePath(&buf[0], &size) != 0) return ".";
    char real[PATH_MAX];
    std::string path = realpath(buf.c_str(), real) ? std::string(real) : std::string(buf.c_str());
    size_t slash = path.find_last_of('/');
    return slash == std::string::npos ? "." : path.substr(0, slash);
}

// Format: one "key = value" per line; '#' starts a comment; values may be quoted.
// Keys: name, plate, vehicle (optional).
static void loadSettings() {
    std::string path = executableDir() + "/" + CONF_NAME;
    FILE *f = fopen(path.c_str(), "r");
    if (!f) {
        LOGW("Settings file not found: " + path + " (using NO NAME SET / NO PLATE SET)");
        return;
    }
    char line[1024];
    int lineNo = 0;
    while (fgets(line, sizeof line, f)) {
        lineNo++;
        std::string l = line;
        size_t hash = l.find('#');
        if (hash != std::string::npos) l = l.substr(0, hash);
        l = trim(l);
        if (l.empty()) continue;
        size_t eq = l.find('=');
        if (eq == std::string::npos) {
            LOGW(fmt("%s:%d: ignoring line without '='", CONF_NAME, lineNo));
            continue;
        }
        std::string key = lower(trim(l.substr(0, eq)));
        std::string val = trim(l.substr(eq + 1));
        if (val.size() >= 2 && (val.front() == '"' || val.front() == '\'') && val.back() == val.front())
            val = val.substr(1, val.size() - 2);
        if (val.empty()) continue;
        if (key == "name") g_settings.name = val;
        else if (key == "plate") g_settings.plate = val;
        else if (key == "vehicle") g_settings.vehicle = val;
        else LOGW(fmt("%s:%d: unknown key '%s'", CONF_NAME, lineNo, key.c_str()));
    }
    fclose(f);
    LOGI("Settings: " + path);
}

// ---- regex (ICU via Foundation) ---------------------------------------------

static NSRegularExpression *rx(const char *pattern, bool multiline = false) {
    NSRegularExpressionOptions opts = NSRegularExpressionCaseInsensitive;
    if (multiline) opts |= NSRegularExpressionAnchorsMatchLines;
    NSError *err = nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:NS(pattern) options:opts error:&err];
    if (!re) {
        LOGE(fmt("Bad regex '%s': %s", pattern, STD(err.localizedDescription).c_str()));
    }
    return re;
}

// Equivalent of re.search(pattern, text, IGNORECASE); returns group 1 (or whole match).
static bool rxSearch(const char *pattern, NSString *text, std::string &out) {
    NSRegularExpression *re = rx(pattern);
    if (!re) return false;
    NSTextCheckingResult *m = [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!m) return false;
    NSRange r = m.numberOfRanges > 1 ? [m rangeAtIndex:1] : m.range;
    if (r.location == NSNotFound) return false;
    out = STD([text substringWithRange:r]);
    return true;
}

// Equivalent of re.findall(pattern, text, IGNORECASE[|MULTILINE]) with one group.
static std::vector<std::string> rxFindAll(const char *pattern, NSString *text, bool multiline = false) {
    std::vector<std::string> out;
    NSRegularExpression *re = rx(pattern, multiline);
    if (!re) return out;
    NSArray *ms = [re matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    for (NSTextCheckingResult *m in ms) {
        NSRange r = m.numberOfRanges > 1 ? [m rangeAtIndex:1] : m.range;
        if (r.location == NSNotFound) continue;
        out.push_back(STD([text substringWithRange:r]));
    }
    return out;
}

static NSUInteger rxCount(const char *pattern, NSString *text) {
    NSRegularExpression *re = rx(pattern);
    if (!re) return 0;
    return [re numberOfMatchesInString:text options:0 range:NSMakeRange(0, text.length)];
}

// ---- dates ------------------------------------------------------------------

struct Date {
    int y = 1970, m = 1, d = 1;
    long key() const { return (long)y * 10000 + m * 100 + d; }
    std::string dmy() const { return fmt("%02d/%02d/%04d", d, m, y); }
};

static int daysInMonth(int y, int m) {
    static const int dm[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    if (m == 2 && ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0)) return 29;
    return dm[m - 1];
}

// Mirrors datetime.strptime after the script's abbreviation normalisation.
static bool parseDate(const std::string &raw, const char *format, Date &out) {
    static const char *abbr[][2] = {{"Jan", "January"}, {"Feb", "February"}, {"Mar", "March"},
                                    {"Apr", "April"},   {"Jun", "June"},     {"Jul", "July"},
                                    {"Aug", "August"},  {"Sep", "September"}, {"Oct", "October"},
                                    {"Nov", "November"}, {"Dec", "December"}};
    NSString *s = NS(raw);
    for (auto &a : abbr) {
        NSRegularExpression *re = rx(fmt("\\b%s\\b", a[0]).c_str());
        s = [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:NS(a[1])];
    }
    std::string str = STD(s);
    struct tm t;
    memset(&t, 0, sizeof t);
    const char *end = strptime(str.c_str(), format, &t);
    if (!end || *end != '\0') return false;
    int y = t.tm_year + 1900, m = t.tm_mon + 1, d = t.tm_mday;
    if (m < 1 || m > 12 || d < 1 || d > daysInMonth(y, m)) return false;
    out.y = y; out.m = m; out.d = d;
    return true;
}

static Date dateFromMtime(const std::string &path) {
    struct stat st;
    Date dt;
    if (stat(path.c_str(), &st) == 0) {
        struct tm lt;
        localtime_r(&st.st_mtime, &lt);
        dt.y = lt.tm_year + 1900; dt.m = lt.tm_mon + 1; dt.d = lt.tm_mday;
    }
    return dt;
}

// Excel serial date (days since 1899-12-30), using the days-from-civil algorithm.
static long excelSerial(const Date &dt) {
    int y = dt.y, m = dt.m, d = dt.d;
    y -= m <= 2;
    const int era = (y >= 0 ? y : y - 399) / 400;
    const unsigned yoe = (unsigned)(y - era * 400);
    const unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    long daysSinceEpoch = era * 146097L + (long)doe - 719468L;   // days since 1970-01-01
    return daysSinceEpoch + 25569;                                 // 1970-01-01 is serial 25569
}

// =============================================================================
// DATA STRUCTURES
// =============================================================================

struct Invoice {
    std::string receipt_no;
    Date date;
    double total_inc_gst = 0;
    std::string provider;
    std::string source_path;
    double confidence = 1.0;

    double total_exc_gst() const { return total_inc_gst / (1 + CFG_GST_RATE); }
    double gst_amount() const { return total_exc_gst() * CFG_GST_RATE; }
};

// =============================================================================
// PROVIDER DETECTION
// =============================================================================

struct ProviderDef { const char *name; std::vector<const char *> patterns; };

static const std::vector<ProviderDef> PROVIDERS = {
    {"EVX",        {R"(EVX\s*AUSTRALIA)", R"(EVX\s*PTY)", R"(evx\.com)", R"(EVX\s+AUSTRALIA\s+PTY\s+LTD)"}},
    {"Tesla",      {R"(TESLA)", R"(SUPERCHARGER)", R"(tesla\.com)", R"(Tesla\s+Motors)", R"(Tesla,?\s*Inc)", R"(Tesla\s+Motors\s+Australia)"}},
    {"EvieCharge", {R"(EVIE)", R"(evie\.com)", R"(Evie\s*Networks)", R"(EVIEMS\d+)", R"(Fast\s+Cities\s+Australia)", R"(charging\s+with\s+Evie)", R"(dba\.?\s*Evie)"}},
    {"Chargefox",  {R"(CHARGEFOX)", R"(chargefox\.com)", R"(Chargefox\s+Pty)"}},
    {"AmpCharge",  {R"(AMPCHARGE)", R"(ampcharge\.com)", R"(AmpCharge\s+Australia)"}},
    {"JOLT",       {R"(JOLT)", R"(jolt\.com)", R"(Jolt\s+Charge)"}},
    {"AGL",        {R"(AGL\s+Sales)", R"(AGL\s+Pty)", R"(agl\.com)", R"(AGL\s+Energy)"}},
};

static void detectProvider(NSString *text, std::string &provider, double &confidence) {
    const ProviderDef *best = nullptr;
    long bestScore = -1;
    for (const auto &p : PROVIDERS) {
        long score = 0;
        for (const char *pat : p.patterns) score += (long)rxCount(pat, text) * 10;
        if (score > bestScore) { best = &p; bestScore = score; }   // first provider wins ties
    }
    if (!best || bestScore <= 0) {
        provider = CFG_DEFAULT_PROVIDER;
        confidence = 0.5;
        return;
    }
    provider = best->name;
    confidence = std::min(bestScore / 30.0, 1.0);
}

// =============================================================================
// DATA EXTRACTION
// =============================================================================

static const char *RECEIPT_PATTERNS[] = {
    // Tesla style: Invoice Number 2010P0001759848 (high priority - specific format)
    R"(Invoice\s+Number\s+(\d{4}[A-Za-z]\d{10,12}))",
    // AmpCharge style: "Tax Invoice 3A1BAF726262", or label/value columns extracted apart
    R"(Tax\s+Invoice\s+(?:Charger\s+ID[\s\S]{0,160}?\n)?((?=[0-9A-F]*\d)[0-9A-F]{12})\b)",
    // EVX style: Receipt No. 0000059428
    R"(Receipt\s*No\.?\s*:?\s*([A-Za-z0-9]{8,12}))",
    R"(Receipt\s*#?\s*:?\s*([A-Za-z0-9]{8,12}))",
    // Invoice style (Tesla, Chargefox)
    R"(Invoice\s*No\.?\s*:?\s*([A-Za-z0-9]{6,20}))",
    R"(Invoice\s*#?\s*:?\s*([A-Za-z0-9]{6,20}))",
    R"(Invoice\s+Number\s*:?\s*([A-Za-z0-9]{10,20}))",
    // AGL style: AUD-1-U2551-2025-10-01
    R"(Receipt\s*No\.?\s*:?\s*(AUD-[\w-]+))",
    R"((AUD-\d+-[A-Za-z]\d+-\d{4}-\d{2}-\d{2}))",
    // Transaction reference
    R"(Transaction\s*(?:No|#|Ref)\.?\s*:?\s*([A-Za-z0-9]{8,20}))",
    // EvieCharge style: EVIEMS236A or MS236B (plug used)
    R"((EVIEMS[A-Za-z0-9]+))",
    R"(\b(MS\d{3}[A-Za-z]?)\b)",
    R"(Plug\s+used\n([A-Za-z0-9]{4,10}))",
    // Reference number
    R"(Reference\s+Number\s+([A-Za-z0-9-]{20,50}))",
    R"(Confirmation\s*(?:No|#)?\s*:?\s*([A-Za-z0-9]{8,20}))",
    // Customer number (Tesla fallback)
    R"(Customer\s+Number\s*:?\s*(\d{8,12}))",
    // Fallback: Any 10-digit number
    R"(\b(\d{10})\b)",
};

struct DatePat { const char *pattern; const char *format; };
static const DatePat DATE_PATTERNS[] = {
    {R"(Date\s*:?\s*(\d{1,2}/\d{1,2}/\d{4}))", "%d/%m/%Y"},
    {R"(Date\s*:?\s*(\d{1,2}-\d{1,2}-\d{4}))", "%d-%m-%Y"},
    {R"(Date\s*:?\s*(\d{1,2}/\d{1,2}/\d{4})\s+\d{1,2}:\d{2})", "%d/%m/%Y"},
    // Tesla format: YYYY/MM/DD
    {R"(Invoice\s+date\s*:?\s*(\d{4}/\d{2}/\d{2}))", "%Y/%m/%d"},
    {R"(Date\s+of\s+Event\s*:?\s*(\d{4}/\d{2}/\d{2}))", "%Y/%m/%d"},
    {R"(\b(\d{4}/\d{2}/\d{2})\b)", "%Y/%m/%d"},
    // ISO
    {R"(Date\s*:?\s*(\d{4}-\d{2}-\d{2}))", "%Y-%m-%d"},
    // EvieCharge: "Sunday 19 October 2025"
    {R"((?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\s+(\d{1,2}\s+(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{4}))", "%d %B %Y"},
    // Written: "19 October 2025"
    {R"((\d{1,2}\s+(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{4}))", "%d %B %Y"},
    {R"(Date\s*:?\s*(\d{1,2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{4}))", "%d %B %Y"},
    {R"(Date\s*:?\s*(\d{1,2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*,?\s+\d{4}))", "%d %B, %Y"},
    {R"(Transaction\s+Date\s*:?\s*(\d{1,2}/\d{1,2}/\d{4}))", "%d/%m/%Y"},
    {R"(Charged\s+on\s*:?\s*(\d{1,2}/\d{1,2}/\d{4}))", "%d/%m/%Y"},
    // Period end date (monthly summaries like AGL)
    {R"(Period\s*:?\s*\d{1,2}/\d{1,2}/\d{4}\s+to\s+(\d{1,2}/\d{1,2}/\d{4}))", "%d/%m/%Y"},
    // Generic DD/MM/YYYY anywhere
    {R"(\b(\d{2}/\d{2}/\d{4})\b)", "%d/%m/%Y"},
};

struct AmountPat { const char *pattern; double weight; bool multiline; };
static const AmountPat AMOUNT_PATTERNS[] = {
    {R"(Total\s+for\s+payment\s*\$?\s*([\d,]+\.?\d*))", 2.0, false},                       // EVX
    {R"(Total\s+incl\.?\s*Tax\s*\$?\s*([\d,]+\.?\d*))", 1.8, false},
    {R"(Total\s+Inc\.?\s*GST\s*\$?\s*([\d,]+\.?\d*))", 1.8, false},
    {R"(Total\s+Amount\s*\(?\s*AUD\s*\)?\s*\$?\s*([\d,]+\.?\d*))", 1.9, false},           // Tesla
    {R"(Charge\s+Cost\s*\(?\s*inc\.?\s*GST\s*\)?\s*\$\s*([\d,]+\.?\d*))", 1.9, false},   // EvieCharge
    {R"(Total\s*\$\s*([\d,]+\.?\d*))", 1.0, false},
    {R"(\$\s+([\d,]+\.\d{2})\b)", 1.4, false},                                             // "$ 35.50"
    {R"(Amount\s+charged\s*:?\s*\$?\s*([\d,]+\.?\d*))", 1.5, false},
    {R"(Total\s+Amount\s*:?\s*\$?\s*([\d,]+\.?\d*))", 1.0, false},
    {R"(Grand\s+Total\s*:?\s*\$?\s*([\d,]+\.?\d*))", 1.0, false},
    {R"(Payment\s+Amount\s*:?\s*\$?\s*([\d,]+\.?\d*))", 1.0, false},
    {R"(Charged\s*:?\s*\$\s*([\d,]+\.?\d*))", 1.0, false},
    {R"(Total\s*:?\s*\$\s*([\d,]+\.?\d*))", 1.0, false},
    {R"(AUD\s*\$?\s*([\d,]+\.?\d*))", 1.0, false},
    {R"(\$\s*([\d,]+\.\d{2})\s*$)", 1.0, true},                                            // last resort
};

// ---- text extraction: PDFKit, then Vision OCR -------------------------------

static NSString *ocrPage(PDFPage *page) {
    CGPDFPageRef pg = page.pageRef;
    if (!pg) return @"";
    CGRect box = CGPDFPageGetBoxRect(pg, kCGPDFMediaBox);
    int rot = CGPDFPageGetRotationAngle(pg);
    double scale = 300.0 / 72.0;
    // Cap the raster so oversized pages (e.g. scans stored at pixel size) stay around 3300 px on the long side.
    double longSide = std::max(box.size.width, box.size.height) * scale;
    if (longSide > 3300) scale *= 3300 / longSide;
    double pw = box.size.width * scale, ph = box.size.height * scale;
    if (rot == 90 || rot == 270) std::swap(pw, ph);
    size_t w = (size_t)std::max(1.0, std::round(pw)), h = (size_t)std::max(1.0, std::round(ph));

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return @"";
    CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGAffineTransform t = CGPDFPageGetDrawingTransform(pg, kCGPDFMediaBox, CGRectMake(0, 0, w, h), 0, true);
    CGContextConcatCTM(ctx, t);
    CGContextDrawPDFPage(ctx, pg);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!img) return @"";

    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.usesLanguageCorrection = NO;   // keep receipt numbers verbatim
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:img options:@{}];
    CGImageRelease(img);
    NSError *err = nil;
    if (![handler performRequests:@[req] error:&err]) {
        // Retry on the CPU: the default compute device can be unavailable (e.g. under Rosetta).
        NSError *err2 = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        req.usesCPUOnly = YES;
#pragma clang diagnostic pop
        bool ok = [handler performRequests:@[req] error:&err2];
        if (!ok) {
            req.recognitionLevel = VNRequestTextRecognitionLevelFast;
            ok = [handler performRequests:@[req] error:&err2];
            if (ok) LOGI("  OCR used the fast recognition model");
        }
        if (!ok) {
            LOGW(fmt("  OCR failed: %s (%s %ld)", STD(err2.localizedDescription).c_str(), STD(err2.domain).c_str(), (long)err2.code));
            return @"";
        }
    }

    struct Line { double x, y, h; std::string text; };
    std::vector<Line> lines;
    for (VNRecognizedTextObservation *o in req.results) {
        VNRecognizedText *c = [o topCandidates:1].firstObject;
        if (!c) continue;
        CGRect b = o.boundingBox;   // normalised, origin bottom-left
        lines.push_back({b.origin.x, b.origin.y + b.size.height / 2, b.size.height, STD(c.string)});
    }
    // top-to-bottom, then left-to-right; fragments on the same visual line are joined.
    std::sort(lines.begin(), lines.end(), [](const Line &a, const Line &b) {
        double tol = std::min(a.h, b.h) * 0.6;
        if (std::fabs(a.y - b.y) > tol) return a.y > b.y;
        return a.x < b.x;
    });
    std::string out;
    for (size_t i = 0; i < lines.size(); i++) {
        if (i > 0) {
            double tol = std::min(lines[i].h, lines[i - 1].h) * 0.6;
            out += (std::fabs(lines[i].y - lines[i - 1].y) <= tol) ? " " : "\n";
        }
        out += lines[i].text;
    }
    return NS(out);
}

static NSString *extractText(const std::string &path) {
    PDFDocument *doc = [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:NS(path)]];
    if (!doc) {
        LOGE(fmt("Failed to extract text from %s: cannot open PDF", path.c_str()));
        return @"";
    }
    NSMutableString *all = [NSMutableString string];
    for (NSUInteger i = 0; i < doc.pageCount; i++) {
        if (i > 0) [all appendString:@"\n"];
        [all appendString:[doc pageAtIndex:i].string ?: @""];
    }
    bool ocr = trim(STD(all)).empty();
    if (ocr) {
        LOGI(fmt("  Attempting OCR for %s...", basenameOf(path).c_str()));
        [all setString:@""];
        for (NSUInteger i = 0; i < doc.pageCount; i++) {
            if (i > 0) [all appendString:@"\n"];
            [all appendString:ocrPage([doc pageAtIndex:i])];
        }
    }
    if (getenv("EVCHARGE_DEBUG")) {
        fprintf(stderr, "----- extracted text (%s) for %s -----\n%s\n-----\n", ocr ? "OCR" : "PDFKit", basenameOf(path).c_str(), STD(all).c_str());
    }
    return all;
}

// ---- field extraction -------------------------------------------------------

static void extractReceiptNumber(NSString *text, const std::string &path, std::string &out, double &conf) {
    for (const char *pat : RECEIPT_PATTERNS) {
        std::string g;
        if (rxSearch(pat, text, g)) {
            out = trim(g);
            conf = (strstr(pat, "Receipt") || strstr(pat, "Invoice")) ? 0.9 : 0.7;
            return;
        }
    }
    LOGW(fmt("Could not extract receipt number from %s, using filename", path.c_str()));
    out = stemOf(path);
    conf = 0.3;
}

static void extractDate(NSString *text, const std::string &path, Date &out, double &conf) {
    for (const auto &dp : DATE_PATTERNS) {
        std::string g;
        if (rxSearch(dp.pattern, text, g)) {
            Date d;
            if (parseDate(trim(g), dp.format, d)) {
                out = d;
                conf = strstr(dp.pattern, "Date") ? 0.95 : 0.7;
                return;
            }
        }
    }
    LOGW(fmt("Could not extract date from %s, using file modification time", path.c_str()));
    out = dateFromMtime(path);
    conf = 0.2;
}

static void extractAmount(NSString *text, const std::string &path, double &out, double &conf) {
    struct Found { double amount, weight; };
    std::vector<Found> found;
    for (const auto &ap : AMOUNT_PATTERNS) {
        for (const std::string &m : rxFindAll(ap.pattern, text, ap.multiline)) {
            std::string s;
            for (char c : m) if (c != ',') s += c;
            if (s.empty()) continue;
            char *end = nullptr;
            double v = strtod(s.c_str(), &end);
            if (end == s.c_str() || *end != '\0') continue;
            if (v > 0.01 && v < 10000) found.push_back({v, ap.weight});
        }
    }
    if (found.empty()) {
        LOGW(fmt("Could not extract amount from %s", path.c_str()));
        out = 0; conf = 0;
        return;
    }
    std::stable_sort(found.begin(), found.end(), [](const Found &a, const Found &b) { return a.weight > b.weight; });
    out = found[0].amount;
    conf = std::min(found[0].weight / 2.0, 0.95);
}

static bool extractInvoice(const std::string &path, Invoice &inv) {
    NSString *text = extractText(path);
    if (trim(STD(text)).empty()) {
        LOGE(fmt("No text extracted from %s", path.c_str()));
        return false;
    }
    double rc, dc, ac, pc;
    extractReceiptNumber(text, path, inv.receipt_no, rc);
    extractDate(text, path, inv.date, dc);
    extractAmount(text, path, inv.total_inc_gst, ac);
    detectProvider(text, inv.provider, pc);
    inv.confidence = (rc + dc + ac + pc) / 4;
    inv.source_path = path;
    if (inv.total_inc_gst <= 0) {
        LOGE(fmt("Invalid amount extracted from %s", path.c_str()));
        return false;
    }
    return true;
}

// =============================================================================
// XLSX WRITER (minimal OOXML + zip container)
// =============================================================================

namespace zipw {

static void put16(std::string &o, uint32_t v) { o.push_back(v & 0xff); o.push_back((v >> 8) & 0xff); }
static void put32(std::string &o, uint32_t v) { put16(o, v & 0xffff); put16(o, (v >> 16) & 0xffff); }

struct Entry { std::string name; uint32_t crc, csize, usize, offset; uint16_t method; };

struct Writer {
    std::string out;
    std::vector<Entry> entries;
    uint16_t dosTime = 0, dosDate = 0;

    Writer() {
        time_t t = time(nullptr);
        struct tm lt;
        localtime_r(&t, &lt);
        dosTime = (uint16_t)((lt.tm_hour << 11) | (lt.tm_min << 5) | (lt.tm_sec / 2));
        dosDate = (uint16_t)(((lt.tm_year - 80) << 9) | ((lt.tm_mon + 1) << 5) | lt.tm_mday);
    }

    void add(const std::string &name, const std::string &data) {
        std::string comp;
        comp.resize(compressBound((uLong)data.size()) + 64);
        z_stream zs;
        memset(&zs, 0, sizeof zs);
        uint16_t method = 0;
        if (deflateInit2(&zs, Z_BEST_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) == Z_OK) {
            zs.next_in = (Bytef *)data.data();
            zs.avail_in = (uInt)data.size();
            zs.next_out = (Bytef *)&comp[0];
            zs.avail_out = (uInt)comp.size();
            if (deflate(&zs, Z_FINISH) == Z_STREAM_END) {
                comp.resize(zs.total_out);
                method = 8;
            }
            deflateEnd(&zs);
        }
        const std::string &payload = (method == 8 && comp.size() < data.size()) ? comp : data;
        if (&payload == &data) method = 0;

        Entry e;
        e.name = name;
        e.crc = (uint32_t)crc32(0L, (const Bytef *)data.data(), (uInt)data.size());
        e.csize = (uint32_t)payload.size();
        e.usize = (uint32_t)data.size();
        e.offset = (uint32_t)out.size();
        e.method = method;

        put32(out, 0x04034b50); put16(out, 20); put16(out, 0); put16(out, method);
        put16(out, dosTime); put16(out, dosDate);
        put32(out, e.crc); put32(out, e.csize); put32(out, e.usize);
        put16(out, (uint32_t)name.size()); put16(out, 0);
        out += name;
        out += payload;
        entries.push_back(e);
    }

    std::string finish() {
        uint32_t cdStart = (uint32_t)out.size();
        for (const Entry &e : entries) {
            put32(out, 0x02014b50); put16(out, 20); put16(out, 20); put16(out, 0); put16(out, e.method);
            put16(out, dosTime); put16(out, dosDate);
            put32(out, e.crc); put32(out, e.csize); put32(out, e.usize);
            put16(out, (uint32_t)e.name.size()); put16(out, 0); put16(out, 0);
            put16(out, 0); put16(out, 0); put32(out, 0); put32(out, e.offset);
            out += e.name;
        }
        uint32_t cdSize = (uint32_t)out.size() - cdStart;
        put32(out, 0x06054b50); put16(out, 0); put16(out, 0);
        put16(out, (uint32_t)entries.size()); put16(out, (uint32_t)entries.size());
        put32(out, cdSize); put32(out, cdStart); put16(out, 0);
        return out;
    }
};

} // namespace zipw

static std::string xmlEscape(const std::string &s) {
    std::string o;
    for (char c : s) {
        switch (c) {
            case '&': o += "&amp;"; break;
            case '<': o += "&lt;"; break;
            case '>': o += "&gt;"; break;
            case '"': o += "&quot;"; break;
            default: o += c;
        }
    }
    return o;
}

// Cell style indices (must match the cellXfs order in STYLES_XML).
enum XfStyle {
    XF_DEFAULT = 0,
    XF_HEADER_LEFT,        // Helvetica 16 bold, left
    XF_HEADER,             // Helvetica 16 bold
    XF_COLHDR_CENTER,      // Helvetica 16, center, bottom border
    XF_COLHDR_RIGHT,       // Helvetica 16, right, bottom border
    XF_SMALL_CENTER,       // Helvetica 12, center
    XF_NORMAL_CENTER,      // Helvetica 16, center
    XF_DATA_DATE,          // Helvetica 16 #18181B, center, DD/MM/YYYY
    XF_DATA_CENTER,        // Helvetica 16 #18181B, center
    XF_NORMAL_RIGHT_2DP,   // Helvetica 16, right, 0.00
    XF_HEADER_2DP,         // Helvetica 16 bold, 0.00
    XF_NORMAL_RIGHT,       // Helvetica 16, right
    XF_SMALL_ITALIC_RIGHT, // Helvetica 12 italic, right
};

static const char *STYLES_XML =
    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
    "<numFmts count=\"1\"><numFmt numFmtId=\"164\" formatCode=\"DD/MM/YYYY\"/></numFmts>"
    "<fonts count=\"6\">"
    "<font><sz val=\"11\"/><name val=\"Calibri\"/><family val=\"2\"/></font>"
    "<font><b/><sz val=\"16\"/><name val=\"Helvetica\"/></font>"
    "<font><sz val=\"16\"/><name val=\"Helvetica\"/></font>"
    "<font><sz val=\"12\"/><name val=\"Helvetica\"/></font>"
    "<font><i/><sz val=\"12\"/><name val=\"Helvetica\"/></font>"
    "<font><sz val=\"16\"/><color rgb=\"FF18181B\"/><name val=\"Helvetica\"/></font>"
    "</fonts>"
    "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>"
    "<borders count=\"2\">"
    "<border><left/><right/><top/><bottom/><diagonal/></border>"
    "<border><left/><right/><top/><bottom style=\"thin\"/><diagonal/></border>"
    "</borders>"
    "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
    "<cellXfs count=\"13\">"
    "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"
    "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyAlignment=\"1\"><alignment horizontal=\"left\"/></xf>"
    "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/>"
    "<xf numFmtId=\"0\" fontId=\"2\" fillId=\"0\" borderId=\"1\" xfId=\"0\" applyFont=\"1\" applyBorder=\"1\" applyAlignment=\"1\"><alignment horizontal=\"center\"/></xf>"
    "<xf numFmtId=\"0\" fontId=\"2\" fillId=\"0\" borderId=\"1\" xfId=\"0\" applyFont=\"1\" applyBorder=\"1\" applyAlignment=\"1\"><alignment horizontal=\"right\"/></xf>"
    "<xf numFmtId=\"0\" fontId=\"3\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyAlignment=\"1\"><alignment horizontal=\"center\"/></xf>"
    "<xf numFmtId=\"0\" fontId=\"2\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyAlignment=\"1\"><alignment horizontal=\"center\"/></xf>"
    "<xf numFmtId=\"164\" fontId=\"5\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\" applyFont=\"1\" applyAlignment=\"1\"><alignment horizontal=\"center\"/></xf>"
    "<xf numFmtId=\"0\" fontId=\"5\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyAlignment=\"1\"><alignment horizontal=\"center\"/></xf>"
    "<xf numFmtId=\"2\" fontId=\"2\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\" applyFont=\"1\" applyAlignment=\"1\"><alignment horizontal=\"right\"/></xf>"
    "<xf numFmtId=\"2\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\" applyFont=\"1\"/>"
    "<xf numFmtId=\"0\" fontId=\"2\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyAlignment=\"1\"><alignment horizontal=\"right\"/></xf>"
    "<xf numFmtId=\"0\" fontId=\"4\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyAlignment=\"1\"><alignment horizontal=\"right\"/></xf>"
    "</cellXfs>"
    "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
    "</styleSheet>";

struct SheetCell {
    std::string ref;
    int style;
    enum { STR, NUM, FORMULA } kind;
    std::string text;   // STR / FORMULA
    double num = 0;     // NUM
};

static std::string cellXml(const SheetCell &c) {
    switch (c.kind) {
        case SheetCell::STR:
            return fmt("<c r=\"%s\" s=\"%d\" t=\"inlineStr\"><is><t>%s</t></is></c>", c.ref.c_str(), c.style, xmlEscape(c.text).c_str());
        case SheetCell::NUM:
            return fmt("<c r=\"%s\" s=\"%d\"><v>%.10g</v></c>", c.ref.c_str(), c.style, c.num);
        case SheetCell::FORMULA:
            return fmt("<c r=\"%s\" s=\"%d\"><f>%s</f></c>", c.ref.c_str(), c.style, xmlEscape(c.text).c_str());
    }
    return "";
}

static void generateExcel(const std::vector<Invoice> &invoices, int month, int year, const std::string &outPath) {
    std::string yy = fmt("%02d", year % 100);
    std::string monthName = MONTH_UPPER[month - 1];

    // rows: map row number -> cells, in column order as we append them.
    std::vector<std::pair<int, std::vector<SheetCell>>> rows;
    auto row = [&](int r) -> std::vector<SheetCell> & {
        for (auto &p : rows) if (p.first == r) return p.second;
        rows.push_back({r, {}});
        return rows.back().second;
    };
    auto str = [&](int r, const char *col, const std::string &v, int style) { row(r).push_back({fmt("%s%d", col, r), style, SheetCell::STR, v}); };
    auto num = [&](int r, const char *col, double v, int style) { SheetCell c{fmt("%s%d", col, r), style, SheetCell::NUM, "", v}; row(r).push_back(c); };
    auto formula = [&](int r, const char *col, const std::string &f, int style) { row(r).push_back({fmt("%s%d", col, r), style, SheetCell::FORMULA, f}); };

    str(2, "A", "CHARGING EXPENSES", XF_HEADER_LEFT);
    str(2, "C", g_settings.vehicleLine(), XF_HEADER);
    str(3, "A", monthName + "'" + yy, XF_HEADER_LEFT);
    str(3, "C", g_settings.name, XF_HEADER);

    str(5, "A", "No", XF_COLHDR_CENTER);
    str(5, "B", "Invoice Date", XF_COLHDR_CENTER);
    str(5, "C", "Invoice No", XF_COLHDR_CENTER);
    str(5, "D", "Total Exc GST", XF_COLHDR_RIGHT);
    str(5, "E", "GST", XF_COLHDR_RIGHT);
    str(5, "F", "Total Inc GST", XF_COLHDR_RIGHT);
    str(5, "H", "check", XF_SMALL_CENTER);

    for (size_t i = 0; i < invoices.size(); i++) {
        int r = 6 + (int)i;
        const Invoice &inv = invoices[i];
        num(r, "A", (double)(i + 1), XF_NORMAL_CENTER);
        num(r, "B", (double)excelSerial(inv.date), XF_DATA_DATE);
        str(r, "C", inv.receipt_no, XF_DATA_CENTER);
        formula(r, "D", fmt("F%d/1.1", r), XF_NORMAL_RIGHT_2DP);
        formula(r, "E", fmt("D%d*0.1", r), XF_NORMAL_RIGHT_2DP);
        num(r, "F", inv.total_inc_gst, XF_NORMAL_RIGHT_2DP);
        formula(r, "H", fmt("F%d-SUM(D%d:E%d)", r, r, r), XF_SMALL_CENTER);
    }

    int lastDataRow = 5 + (int)invoices.size();
    int totalRow = lastDataRow + 2;
    str(totalRow, "E", "TOTAL", XF_HEADER);
    formula(totalRow, "F", fmt("SUM(F6:F%d)", lastDataRow + 1), XF_HEADER_2DP);
    str(totalRow + 1, "F", "including GST", XF_NORMAL_RIGHT);
    int footerRow = totalRow + 3;
    str(footerRow, "F", "In the following pages, the invoices listed above.", XF_SMALL_ITALIC_RIGHT);

    // ---- sheet1.xml
    std::string sheet =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
        "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
        "<sheetPr><pageSetUpPr fitToPage=\"1\"/></sheetPr>" +
        fmt("<dimension ref=\"A2:H%d\"/>", footerRow) +
        "<sheetViews><sheetView workbookViewId=\"0\"/></sheetViews>"
        "<sheetFormatPr baseColWidth=\"8\" defaultRowHeight=\"15\"/>"
        "<cols>"
        "<col min=\"1\" max=\"1\" width=\"11.17\" customWidth=\"1\"/>"
        "<col min=\"2\" max=\"2\" width=\"25.83\" customWidth=\"1\"/>"
        "<col min=\"3\" max=\"3\" width=\"35.33\" customWidth=\"1\"/>"
        "<col min=\"4\" max=\"4\" width=\"19\" customWidth=\"1\"/>"
        "<col min=\"5\" max=\"5\" width=\"10.5\" customWidth=\"1\"/>"
        "<col min=\"6\" max=\"6\" width=\"18.67\" customWidth=\"1\"/>"
        "<col min=\"7\" max=\"7\" width=\"3.5\" customWidth=\"1\"/>"
        "<col min=\"8\" max=\"8\" width=\"10.83\" customWidth=\"1\"/>"
        "</cols><sheetData>";

    auto rowHeight = [&](int r) -> double {
        if (r == 5) return 30.0;
        if (r >= 2 && r <= footerRow) return 21.0;
        return 0;
    };
    for (int r = 2; r <= footerRow; r++) {
        const std::vector<SheetCell> *cells = nullptr;
        for (auto &p : rows) if (p.first == r) cells = &p.second;
        double h = rowHeight(r);
        if (!cells && h <= 0) continue;
        sheet += fmt("<row r=\"%d\"", r);
        if (h > 0) sheet += fmt(" ht=\"%g\" customHeight=\"1\"", h);
        sheet += ">";
        if (cells) for (const SheetCell &c : *cells) sheet += cellXml(c);
        sheet += "</row>";
    }
    sheet += "</sheetData>"
             "<pageMargins left=\"0.5\" right=\"0.5\" top=\"0.5\" bottom=\"0.5\" header=\"0.3\" footer=\"0.3\"/>"
             "<pageSetup orientation=\"landscape\" paperSize=\"9\" fitToWidth=\"1\" fitToHeight=\"1\"/>"
             "</worksheet>";

    std::string workbook =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
        "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
        "<workbookPr/><bookViews><workbookView/></bookViews>"
        "<sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets>"
        "<definedNames><definedName name=\"_xlnm.Print_Area\" localSheetId=\"0\">'Sheet1'!$A$2:$F$" + fmt("%d", footerRow) + "</definedName></definedNames>"
        "<calcPr calcId=\"191029\" fullCalcOnLoad=\"1\"/>"
        "</workbook>";

    zipw::Writer z;
    z.add("[Content_Types].xml",
          "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
          "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
          "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
          "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
          "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
          "<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
          "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
          "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
          "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"
          "</Types>");
    z.add("_rels/.rels",
          "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
          "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
          "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
          "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>"
          "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/>"
          "</Relationships>");
    z.add("docProps/core.xml",
          "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
          "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" "
          "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" "
          "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
          "<dc:creator>evcharge</dc:creator></cp:coreProperties>");
    z.add("docProps/app.xml",
          "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
          "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\">"
          "<Application>evcharge</Application></Properties>");
    z.add("xl/workbook.xml", workbook);
    z.add("xl/_rels/workbook.xml.rels",
          "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
          "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
          "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>"
          "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
          "</Relationships>");
    z.add("xl/styles.xml", STYLES_XML);
    z.add("xl/worksheets/sheet1.xml", sheet);

    std::string bytes = z.finish();
    FILE *f = fopen(outPath.c_str(), "wb");
    if (!f) throw std::runtime_error("Cannot write " + outPath);
    fwrite(bytes.data(), 1, bytes.size(), f);
    fclose(f);
    LOGI("Excel file saved: " + outPath);
}

// =============================================================================
// SUMMARY PDF (CoreGraphics + CoreText), layout mirrors the reportlab version
// =============================================================================

static const double PT_PER_MM = 72.0 / 25.4;
static const double PAGE_W = 297 * PT_PER_MM;   // A4 landscape
static const double PAGE_H = 210 * PT_PER_MM;
static const double MARGIN = 15 * PT_PER_MM;
static const double FRAME_PAD = 6;              // reportlab Frame default padding
static const double CELL_PAD_X = 6;             // reportlab Table default cell padding
static const double CELL_PAD_Y = 3;
static const double CELL_LEADING = 12;         // reportlab TableStyle default LEADING

enum Align { LEFT, CENTER, RIGHT };

static CTLineRef makeLine(CTFontRef font, const std::string &text) {
    NSDictionary *attrs = @{(id)kCTFontAttributeName: (__bridge id)font,
                            (id)kCTForegroundColorFromContextAttributeName: @YES};
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:NS(text) attributes:attrs];
    return CTLineCreateWithAttributedString((CFAttributedStringRef)as);
}

// maxWidth > 0 shrinks the font so the text fits (e.g. long AGL receipt numbers).
static void drawText(CGContextRef ctx, CTFontRef font, const std::string &text, double x, double y, Align align,
                     double maxWidth = 0) {
    CTLineRef line = makeLine(font, text);
    double w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    if (maxWidth > 0 && w > maxWidth) {
        CTFontRef small = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * maxWidth / w, NULL, NULL);
        CFRelease(line);
        line = makeLine(small, text);
        CFRelease(small);
        w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    }
    if (align == CENTER) x -= w / 2;
    else if (align == RIGHT) x -= w;
    CGContextSetTextPosition(ctx, x, y);
    CTLineDraw(line, ctx);
    CFRelease(line);
}

static NSData *generateSummaryPDF(const std::vector<Invoice> &invoices, int month, int year) {
    NSMutableData *data = [NSMutableData data];
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData((CFMutableDataRef)data);
    CGRect mediaBox = CGRectMake(0, 0, PAGE_W, PAGE_H);
    NSDictionary *info = @{(id)kCGPDFContextTitle: @"Charging Expenses", (id)kCGPDFContextCreator: @"evcharge"};
    CGContextRef ctx = CGPDFContextCreate(consumer, &mediaBox, (CFDictionaryRef)info);
    CGDataConsumerRelease(consumer);

    CTFontRef bold16 = CTFontCreateWithName(CFSTR("Helvetica-Bold"), 16, NULL);
    CTFontRef reg14 = CTFontCreateWithName(CFSTR("Helvetica"), 14, NULL);
    CTFontRef ital10 = CTFontCreateWithName(CFSTR("Helvetica-Oblique"), 10, NULL);

    const double left = MARGIN + FRAME_PAD;
    const double right = PAGE_W - MARGIN - FRAME_PAD;
    const double top = PAGE_H - MARGIN - FRAME_PAD;
    const double bottom = MARGIN + FRAME_PAD;

    double y = top;
    auto beginPage = [&]() {
        CGContextBeginPage(ctx, &mediaBox);
        CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);
        CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
        CGContextSetRGBStrokeColor(ctx, 0, 0, 0, 1);
        y = top;
    };
    auto endPage = [&]() { CGContextEndPage(ctx); };

    // Baseline inside a row of height h whose top edge is at y: bottom padding + descent allowance.
    auto baseline = [](double rowTop, double h, double fontSize) { (void)fontSize; return rowTop - h + CELL_PAD_Y + 2.5; };

    beginPage();

    // ---- header table: col widths 80 / 40 / 100 mm, Helvetica-Bold 16
    {
        const double hRow = CELL_LEADING + 2 * CELL_PAD_Y;
        const double hdrW = (80 + 40 + 100) * PT_PER_MM;
        const double hdrLeft = (left + right) / 2 - hdrW / 2;   // reportlab hAlign CENTER
        const double c0 = hdrLeft + CELL_PAD_X;
        const double c2 = hdrLeft + (80 + 40) * PT_PER_MM + CELL_PAD_X;
        std::string yy = fmt("%02d", year % 100);
        drawText(ctx, bold16, "CHARGING EXPENSES", c0, baseline(y, hRow, 16), LEFT);
        drawText(ctx, bold16, g_settings.vehicleLine(), c2, baseline(y, hRow, 16), LEFT);
        y -= hRow;
        drawText(ctx, bold16, std::string(MONTH_UPPER[month - 1]) + "'" + yy, c0, baseline(y, hRow, 16), LEFT);
        drawText(ctx, bold16, g_settings.name, c2, baseline(y, hRow, 16), LEFT);
        y -= hRow;
    }
    y -= 10 * PT_PER_MM;   // Spacer

    // ---- data table
    const double colW[6] = {15 * PT_PER_MM, 35 * PT_PER_MM, 45 * PT_PER_MM, 35 * PT_PER_MM, 25 * PT_PER_MM, 35 * PT_PER_MM};
    const Align colAlign[6] = {CENTER, CENTER, CENTER, RIGHT, RIGHT, RIGHT};
    double tableW = 0;
    for (double w : colW) tableW += w;
    double colX[7];
    colX[0] = (left + right) / 2 - tableW / 2;   // reportlab hAlign CENTER
    for (int i = 0; i < 6; i++) colX[i + 1] = colX[i] + colW[i];

    auto cellX = [&](int col) {
        switch (colAlign[col]) {
            case LEFT: return colX[col] + CELL_PAD_X;
            case CENTER: return (colX[col] + colX[col + 1]) / 2;
            default: return colX[col + 1] - CELL_PAD_X;
        }
    };
    auto drawRow = [&](const std::vector<std::string> &cells, CTFontRef font, double fontSize, double h,
                       CTFontRef boldFont = NULL) {
        for (int c = 0; c < 6 && c < (int)cells.size(); c++) {
            if (cells[c].empty()) continue;
            CTFontRef f = (boldFont && c >= 4) ? boldFont : font;
            double fs = (boldFont && c >= 4) ? 16 : fontSize;
            drawText(ctx, f, cells[c], cellX(c), baseline(y, h, fs), colAlign[c], colW[c] - 2 * CELL_PAD_X);
        }
        y -= h;
    };

    const double hData = CELL_LEADING + 2 * CELL_PAD_Y;
    const double hTotal = CELL_LEADING + 2 * CELL_PAD_Y;
    auto drawHeaderRow = [&]() {
        drawRow({"No", "Invoice Date", "Invoice No", "Total Exc GST", "GST", "Total Inc GST"}, reg14, 14, hData);
        CGContextSetLineWidth(ctx, 1);
        CGContextMoveToPoint(ctx, colX[0], y);
        CGContextAddLineToPoint(ctx, colX[0] + tableW, y);
        CGContextStrokePath(ctx);
    };
    auto ensureSpace = [&](double h) {
        if (y - h < bottom) {
            endPage();
            beginPage();
            drawHeaderRow();
        }
    };

    drawHeaderRow();
    double total = 0;
    for (size_t i = 0; i < invoices.size(); i++) {
        const Invoice &inv = invoices[i];
        total += inv.total_inc_gst;
        ensureSpace(hData);
        drawRow({fmt("%zu", i + 1), inv.date.dmy(), inv.receipt_no,
                 fmt("%.2f", inv.total_exc_gst()), fmt("%.2f", inv.gst_amount()), fmt("%.2f", inv.total_inc_gst)},
                reg14, 14, hData);
    }
    ensureSpace(hData + hTotal + hData);
    y -= hData;   // blank row
    drawRow({"", "", "", "", "TOTAL", fmt("%.2f", total)}, reg14, 14, hTotal, bold16);
    drawRow({"", "", "", "", "", "including GST"}, reg14, 14, hData);

    y -= 15 * PT_PER_MM;   // Spacer
    ensureSpace(12);
    drawText(ctx, ital10, "In the following pages, the invoices listed above.", right, y - 10, RIGHT);

    endPage();
    CGPDFContextClose(ctx);
    CGContextRelease(ctx);
    CFRelease(bold16);
    CFRelease(reg14);
    CFRelease(ital10);
    return data;
}

// =============================================================================
// PDF MERGE (PDFKit)
// =============================================================================

static void mergePDFs(NSData *summary, const std::vector<std::string> &paths, const std::string &outPath) {
    PDFDocument *out = [[PDFDocument alloc] init];
    auto append = [&](PDFDocument *doc) {
        for (NSUInteger i = 0; i < doc.pageCount; i++) [out insertPage:[doc pageAtIndex:i] atIndex:out.pageCount];
    };
    PDFDocument *sdoc = [[PDFDocument alloc] initWithData:summary];
    if (sdoc) append(sdoc); else LOGE("Failed to load generated summary PDF");
    for (const std::string &p : paths) {
        PDFDocument *d = [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:NS(p)]];
        if (d) append(d); else LOGE("Failed to read " + p);
    }
    if (![out writeToURL:[NSURL fileURLWithPath:NS(outPath)]]) throw std::runtime_error("Failed to write " + outPath);
    LOGI("Merged PDF saved: " + outPath);
}

// =============================================================================
// MAIN PROCESSOR
// =============================================================================

static std::vector<std::string> findPdfFiles(const std::string &folder) {
    std::vector<std::string> out;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    NSArray *names = [fm contentsOfDirectoryAtPath:NS(folder) error:&err];
    if (!names) throw std::runtime_error("Cannot list " + folder + ": " + STD(err.localizedDescription));
    std::vector<std::string> sorted;
    for (NSString *n in names) sorted.push_back(STD(n));
    std::sort(sorted.begin(), sorted.end());
    for (const std::string &n : sorted) {
        if (endsWith(lower(n), ".pdf") && !endsWith(n, "_Charging_Total.pdf")) {
            BOOL isDir = NO;
            std::string full = folder + "/" + n;
            if ([fm fileExistsAtPath:NS(full) isDirectory:&isDir] && !isDir) out.push_back(full);
        }
    }
    LOGI(fmt("Found %zu PDF files", out.size()));
    return out;
}

static void copyFile(const std::string &src, const std::string &dst) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    if ([fm fileExistsAtPath:NS(dst)]) [fm removeItemAtPath:NS(dst) error:nil];
    if (![fm copyItemAtPath:NS(src) toPath:NS(dst) error:&err])
        throw std::runtime_error("Copy failed: " + STD(err.localizedDescription));
}

static int run(const std::string &sourceFolderArg) {
    NSString *abs = NS(sourceFolderArg);
    if (![abs isAbsolutePath]) abs = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:abs];
    std::string sourceFolder = STD([[abs stringByStandardizingPath] stringByResolvingSymlinksInPath]);
    LOGI(fmt("Starting EV Charging Processor v%s", EVCHARGE_VERSION));
    loadSettings();
    LOGI("Source folder: " + sourceFolder);

    std::vector<std::string> pdfs = findPdfFiles(sourceFolder);
    if (pdfs.empty()) {
        LOGE("No PDF files found in source folder");
        return 0;
    }

    std::vector<Invoice> invoices;
    for (const std::string &p : pdfs) {
        LOGI("Processing: " + basenameOf(p));
        Invoice inv;
        if (extractInvoice(p, inv)) {
            LOGI(fmt("  \xE2\x9C\x93 %s | %s | $%.2f | Confidence: %.0f%%", inv.provider.c_str(), inv.date.dmy().c_str(),
                     inv.total_inc_gst, inv.confidence * 100));
            invoices.push_back(inv);
        } else {
            LOGW(fmt("  \xE2\x9C\x97 Failed to extract data from %s", basenameOf(p).c_str()));
        }
    }
    if (invoices.empty()) {
        LOGE("No valid invoices extracted");
        return 0;
    }
    std::stable_sort(invoices.begin(), invoices.end(), [](const Invoice &a, const Invoice &b) { return a.date.key() < b.date.key(); });

    int month = invoices[0].date.m, year = invoices[0].date.y;
    std::string yy = fmt("%02d", year % 100);
    std::string outFolder = sourceFolder + fmt("/%02d-%s_Charging", month, yy.c_str());
    NSError *err = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:NS(outFolder) withIntermediateDirectories:YES attributes:nil error:&err])
        throw std::runtime_error("Cannot create output folder: " + STD(err.localizedDescription));
    LOGI("Output folder: " + outFolder);

    std::string monthName = MONTH_TITLE[month - 1];
    generateExcel(invoices, month, year, outFolder + "/" + monthName + yy + "_Charging_Total.xlsx");

    NSData *summary = generateSummaryPDF(invoices, month, year);
    LOGI("PDF summary generated (" + fmt("%lu", (unsigned long)summary.length) + " bytes)");

    std::vector<std::string> renamed;
    for (size_t i = 0; i < invoices.size(); i++) {
        std::string name = fmt("%02zu_%02d-%s %s.pdf", i + 1, month, yy.c_str(), invoices[i].provider.c_str());
        copyFile(invoices[i].source_path, outFolder + "/" + name);
        renamed.push_back(outFolder + "/" + name);
        LOGI("Copied: " + name);
    }

    std::string finalPdf = outFolder + "/" + monthName + yy + "_Charging_Total.pdf";
    mergePDFs(summary, renamed, finalPdf);

    // ---- summary
    double total = 0, conf = 0;
    for (const Invoice &inv : invoices) { total += inv.total_inc_gst; conf += inv.confidence; }
    conf /= invoices.size();
    std::string bar(60, '='), dash(60, '-');
    printf("\n%s\nPROCESSING COMPLETE\n%s\n", bar.c_str(), bar.c_str());
    printf("Output folder:    %s\n", outFolder.c_str());
    printf("Invoices found:   %zu\n", invoices.size());
    printf("Total amount:     $%.2f (inc GST)\n", total);
    printf("Avg confidence:   %.0f%%\n", conf * 100);
    printf("%s\nFiles created:\n", dash.c_str());
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:NS(outFolder) error:nil];
    std::vector<std::string> created;
    for (NSString *n in names) created.push_back(STD(n));
    std::sort(created.begin(), created.end());
    for (const std::string &n : created) printf("  \xE2\x80\xA2 %s\n", n.c_str());
    printf("%s\n", bar.c_str());
    return 0;
}

int main(int argc, char **argv) {
    setlocale(LC_ALL, "C");
    @autoreleasepool {
        std::string folder;
        if (argc > 1) {
            if (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
                printf("evcharge %s\nUsage: %s [folder]\nProcesses EV charging invoice PDFs in folder (default: current directory).\n"
                       "Settings are read from %s next to the executable.\n", EVCHARGE_VERSION, argv[0], CONF_NAME);
                return 0;
            }
            if (strcmp(argv[1], "-v") == 0 || strcmp(argv[1], "--version") == 0) {
                printf("evcharge %s\n", EVCHARGE_VERSION);
                return 0;
            }
            folder = argv[1];
        } else {
            char cwd[4096];
            folder = getcwd(cwd, sizeof cwd) ? cwd : ".";
        }
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:NS(folder) isDirectory:&isDir] || !isDir) {
            printf("Error: '%s' is not a valid directory\n", folder.c_str());
            return 1;
        }
        try {
            return run(folder);
        } catch (const std::exception &e) {
            LOGE(fmt("Processing failed: %s", e.what()));
            return 1;
        }
    }
}
