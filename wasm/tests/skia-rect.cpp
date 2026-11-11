// Smoke test for deps/skia.sh: draws into an SkBitmap on the CPU and writes it as a PNG.
// usage: skia-rect OUT.png [FONT.ttf]
// A rectangle, a round rect cut by SkPathOps, and, given a font file, a line of text through FreeType
// (SkFontMgr_New_Custom_Empty, which is what Ladybird's Compositor uses on Linux).
#include <core/SkBitmap.h>
#include <core/SkCanvas.h>
#include <core/SkData.h>
#include <core/SkFont.h>
#include <core/SkFontMgr.h>
#include <core/SkPaint.h>
#include <core/SkPath.h>
#include <core/SkRRect.h>
#include <core/SkStream.h>
#include <core/SkTypeface.h>
#include <encode/SkPngEncoder.h>
#include <pathops/SkPathOps.h>
#include <ports/SkFontMgr_empty.h>
#include <cstdio>

int main(int argc, char** argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s OUT.png [FONT.ttf]\n", argv[0]);
        return 2;
    }
    SkBitmap bitmap;
    bitmap.allocN32Pixels(256, 160);
    SkCanvas canvas(bitmap);
    canvas.clear(SK_ColorWHITE);

    SkPaint paint;
    paint.setAntiAlias(true);
    paint.setColor(SkColorSetRGB(0x2a, 0x6f, 0xdb));
    canvas.drawRect(SkRect::MakeXYWH(16, 16, 112, 64), paint);

    SkPath rounded = SkPath::RRect(SkRRect::MakeRectXY(SkRect::MakeXYWH(96, 40, 128, 80), 20, 20));
    SkPath hole = SkPath::Circle(160, 80, 24);
    SkPath cut;
    if (!Op(rounded, hole, kDifference_SkPathOp, &cut)) {
        fprintf(stderr, "path op failed\n");
        return 1;
    }
    paint.setColor(SkColorSetARGB(0xc0, 0xe8, 0x5d, 0x2a));
    canvas.drawPath(cut, paint);

    if (argc > 2) {
        sk_sp<SkFontMgr> manager = SkFontMgr_New_Custom_Empty();
        sk_sp<SkTypeface> typeface = manager->makeFromData(SkData::MakeFromFileName(argv[2]));
        if (!typeface) {
            fprintf(stderr, "could not load %s\n", argv[2]);
            return 1;
        }
        SkFont font(typeface, 22);
        paint.setColor(SK_ColorBLACK);
        canvas.drawString("webby wasm32", 16, 148, font, paint);
    }

    SkFILEWStream out(argv[1]);
    if (!out.isValid() || !SkPngEncoder::Encode(&out, bitmap.pixmap(), {})) {
        fprintf(stderr, "could not write %s\n", argv[1]);
        return 1;
    }
    SkColor center = bitmap.getColor(40, 40);
    printf("wrote %s, pixel (40,40) = #%06x\n", argv[1], center & 0xffffff);
    return center == SkColorSetRGB(0x2a, 0x6f, 0xdb) ? 0 : 1;
}
