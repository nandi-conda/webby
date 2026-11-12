/* webby-pdf for wasm: MuPDF behind webby:pdf's documents (wit/pdf.wit), the renderer of the PDF viewer in webby's
 * Qt UI (wasm/ui/PdfView.cpp). It does what nim/pdf/webby-pdf.c does for the Nim front end (open, render a page,
 * a page's characters and links), as a component instead of a process: `wac plug` puts it into webby.wasm, where
 * it has its own memory and symbols (MuPDF brings its own FreeType, HarfBuzz, zlib and libjpeg).
 *
 * Built (deps/mupdf.sh's MuPDF, wasm/ui/CMakeLists.txt's webby-pdf target), this component is under the AGPL-3.0
 * as MuPDF is; this file itself is BSD-2-Clause like the rest of webby.
 *
 * Every call runs inside fz_try, so a damaged PDF gives an error result, not a trap. The canonical ABI gives this
 * side the arguments' memory and frees what it returns after the call (post-return), so results are malloc'd. */
#include "pdf.h"
#include <mupdf/fitz.h>
#include <errno.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef exports_webby_pdf_documents_document_t Doc;

struct exports_webby_pdf_documents_document_t {
    fz_document *doc;
    fz_buffer *buffer;
    int pages;
};

static fz_context *ctx;

/* MuPDF gives NaN for a position a PDF leaves out (an outline entry or link that names only a page). */
static float fin(float v) { return isfinite(v) ? v : 0; }

static void set_string(pdf_string_t *s, const char *text)
{
    size_t n = text ? strlen(text) : 0;
    s->ptr = malloc(n ? n : 1);
    s->len = n;
    if (n)
        memcpy(s->ptr, text, n);
}

static bool start(pdf_string_t *err)
{
    if (ctx)
        return true;
    ctx = fz_new_context(NULL, NULL, 256 << 20);
    if (!ctx) {
        set_string(err, "cannot start MuPDF");
        return false;
    }
    fz_register_document_handlers(ctx);
    /* Warnings about damaged files would go to stderr, which nobody reads. */
    fz_set_warning_callback(ctx, NULL, NULL);
    return true;
}

bool exports_webby_pdf_documents_static_document_open(pdf_list_u8_t *data, pdf_string_t *mime,
    exports_webby_pdf_documents_own_document_t *ret, pdf_string_t *err)
{
    char kind[128] = "application/pdf";
    if (mime->len && mime->len < sizeof kind) {
        memcpy(kind, mime->ptr, mime->len);
        kind[mime->len] = 0;
    }
    free(mime->ptr);
    if (!start(err)) {
        free(data->ptr);
        return false;
    }
    Doc *d = calloc(1, sizeof *d);
    bool ok = false;
    fz_stream *stream = NULL;
    fz_var(stream);
    fz_try(ctx)
    {
        /* The buffer owns the bytes from here on (fz_drop_buffer frees them). */
        d->buffer = fz_new_buffer_from_data(ctx, data->ptr, data->len);
        data->ptr = NULL;
        stream = fz_open_buffer(ctx, d->buffer);
        d->doc = fz_open_document_with_stream(ctx, kind, stream);
        if (fz_needs_password(ctx, d->doc) && !fz_authenticate_password(ctx, d->doc, ""))
            fz_throw(ctx, FZ_ERROR_GENERIC, "the PDF is password protected");
        d->pages = fz_count_pages(ctx, d->doc);
        ok = true;
    }
    fz_always(ctx) fz_drop_stream(ctx, stream);
    fz_catch(ctx)
    {
        set_string(err, fz_caught_message(ctx));
        fz_drop_document(ctx, d->doc);
        fz_drop_buffer(ctx, d->buffer);
        free(d);
    }
    free(data->ptr);
    if (ok)
        *ret = exports_webby_pdf_documents_document_new(d);
    return ok;
}

void exports_webby_pdf_documents_document_destructor(Doc *d)
{
    fz_drop_document(ctx, d->doc);
    fz_drop_buffer(ctx, d->buffer);
    free(d);
}

typedef struct {
    exports_webby_pdf_documents_outline_entry_t *ptr;
    size_t len, cap;
} Outline;

static void add_outline(Doc *d, fz_outline *o, unsigned level, Outline *out)
{
    for (; o; o = o->next) {
        if (out->len == out->cap) {
            out->cap = out->cap ? out->cap * 2 : 32;
            out->ptr = realloc(out->ptr, out->cap * sizeof *out->ptr);
        }
        exports_webby_pdf_documents_outline_entry_t *e = &out->ptr[out->len++];
        e->level = level;
        set_string(&e->title, o->title);
        e->page = -1;
        if (o->page.page >= 0) {
            fz_try(ctx) e->page = fz_page_number_from_location(ctx, d->doc, o->page);
            fz_catch(ctx) e->page = -1;
        }
        e->y = fin(o->y);
        if (o->down)
            add_outline(d, o->down, level + 1, out);
    }
}

void exports_webby_pdf_documents_method_document_info(Doc *d, exports_webby_pdf_documents_info_t *ret)
{
    memset(ret, 0, sizeof *ret);
    ret->pages.len = d->pages;
    ret->pages.ptr = calloc(d->pages ? d->pages : 1, sizeof *ret->pages.ptr);
    for (int i = 0; i < d->pages; i++) {
        fz_rect r = fz_make_rect(0, 0, 612, 792);
        fz_page *page = NULL;
        fz_var(page);
        fz_try(ctx)
        {
            page = fz_load_page(ctx, d->doc, i);
            r = fz_bound_page(ctx, page);
        }
        fz_always(ctx) fz_drop_page(ctx, page);
        fz_catch(ctx) r = fz_make_rect(0, 0, 612, 792);
        ret->pages.ptr[i].width = fin(r.x1 - r.x0) > 0 ? fin(r.x1 - r.x0) : 612;
        ret->pages.ptr[i].height = fin(r.y1 - r.y0) > 0 ? fin(r.y1 - r.y0) : 792;
    }
    char title[1024] = "";
    fz_try(ctx) fz_lookup_metadata(ctx, d->doc, FZ_META_INFO_TITLE, title, sizeof title);
    fz_catch(ctx) title[0] = 0;
    set_string(&ret->title, title);
    fz_outline *outline = NULL;
    fz_var(outline);
    fz_try(ctx) outline = fz_load_outline(ctx, d->doc);
    fz_catch(ctx) outline = NULL;
    Outline out = { 0 };
    add_outline(d, outline, 0, &out);
    fz_drop_outline(ctx, outline);
    ret->outline.ptr = out.ptr;
    ret->outline.len = out.len;
}

bool exports_webby_pdf_documents_method_document_render(Doc *d, uint32_t pageno, float scale,
    exports_webby_pdf_documents_pixels_t *ret, pdf_string_t *err)
{
    if ((int)pageno >= d->pages) {
        set_string(err, "no such page");
        return false;
    }
    if (!(scale > 0) || scale > 20)
        scale = 1;
    fz_page *page = NULL;
    fz_pixmap *pix = NULL;
    fz_device *dev = NULL;
    bool ok = false;
    fz_var(page);
    fz_var(pix);
    fz_var(dev);
    fz_try(ctx)
    {
        page = fz_load_page(ctx, d->doc, pageno);
        fz_rect b = fz_bound_page(ctx, page);
        /* The page's top left at the pixmap's origin. */
        fz_matrix m = fz_concat(fz_translate(-b.x0, -b.y0), fz_scale(scale, scale));
        fz_irect box = fz_round_rect(fz_transform_rect(b, m));
        box.x1 = box.x0 + fz_maxi(1, box.x1 - box.x0);
        box.y1 = box.y0 + fz_maxi(1, box.y1 - box.y0);
        pix = fz_new_pixmap_with_bbox(ctx, fz_device_bgr(ctx), box, NULL, 1);
        fz_clear_pixmap_with_value(ctx, pix, 255);
        dev = fz_new_draw_device(ctx, m, pix);
        fz_run_page(ctx, page, dev, fz_identity, NULL);
        fz_close_device(ctx, dev);
        int w = fz_pixmap_width(ctx, pix), h = fz_pixmap_height(ctx, pix);
        size_t stride = fz_pixmap_stride(ctx, pix), row = (size_t)w * 4;
        unsigned char *s = fz_pixmap_samples(ctx, pix);
        ret->width = w;
        ret->height = h;
        ret->data.len = row * h;
        ret->data.ptr = malloc(ret->data.len ? ret->data.len : 1);
        for (int y = 0; y < h; y++)
            memcpy(ret->data.ptr + row * y, s + stride * y, row);
        ok = true;
    }
    fz_always(ctx)
    {
        fz_drop_device(ctx, dev);
        fz_drop_pixmap(ctx, pix);
        fz_drop_page(ctx, page);
    }
    fz_catch(ctx) set_string(err, fz_caught_message(ctx));
    return ok;
}

typedef struct {
    exports_webby_pdf_documents_list_char_box_t *ptr;
    size_t len, cap;
} Lines;

static void add_blocks(fz_stext_block *block, float x0, float y0, Lines *out)
{
    for (; block; block = block->next) {
        if (block->type == FZ_STEXT_BLOCK_STRUCT) {
            if (block->u.s.down)
                add_blocks(block->u.s.down->first_block, x0, y0, out);
            continue;
        }
        if (block->type != FZ_STEXT_BLOCK_TEXT)
            continue;
        for (fz_stext_line *line = block->u.t.first_line; line; line = line->next) {
            size_t n = 0;
            for (fz_stext_char *ch = line->first_char; ch; ch = ch->next)
                n++;
            if (!n)
                continue;
            if (out->len == out->cap) {
                out->cap = out->cap ? out->cap * 2 : 64;
                out->ptr = realloc(out->ptr, out->cap * sizeof *out->ptr);
            }
            exports_webby_pdf_documents_list_char_box_t *l = &out->ptr[out->len++];
            l->len = n;
            l->ptr = malloc(n * sizeof *l->ptr);
            size_t i = 0;
            for (fz_stext_char *ch = line->first_char; ch; ch = ch->next, i++) {
                fz_rect r = fz_rect_from_quad(ch->quad);
                l->ptr[i] = (exports_webby_pdf_documents_char_box_t) { fin(r.x0 - x0), fin(r.y0 - y0), fin(r.x1 - x0),
                    fin(r.y1 - y0), (uint32_t)ch->c };
            }
        }
    }
}

bool exports_webby_pdf_documents_method_document_text(Doc *d, uint32_t pageno,
    exports_webby_pdf_documents_page_text_t *ret, pdf_string_t *err)
{
    if ((int)pageno >= d->pages) {
        set_string(err, "no such page");
        return false;
    }
    fz_page *page = NULL;
    fz_stext_page *text = NULL;
    fz_link *links = NULL;
    Lines lines = { 0 };
    bool ok = false;
    fz_var(page);
    fz_var(text);
    fz_var(links);
    memset(ret, 0, sizeof *ret);
    fz_try(ctx)
    {
        page = fz_load_page(ctx, d->doc, pageno);
        fz_rect b = fz_bound_page(ctx, page);
        fz_stext_options opts = { 0 };
        text = fz_new_stext_page_from_page(ctx, page, &opts);
        add_blocks(text->first_block, b.x0, b.y0, &lines);
        fz_try(ctx) links = fz_load_links(ctx, page);
        fz_catch(ctx) links = NULL;
        size_t n = 0;
        for (fz_link *l = links; l; l = l->next)
            n++;
        ret->links.ptr = calloc(n ? n : 1, sizeof *ret->links.ptr);
        for (fz_link *l = links; l; l = l->next) {
            if (!l->uri)
                continue;
            int target = -1;
            float tx = 0, ty = 0;
            if (!fz_is_external_link(ctx, l->uri)) {
                fz_try(ctx)
                {
                    fz_location loc = fz_resolve_link(ctx, d->doc, l->uri, &tx, &ty);
                    if (loc.page >= 0)
                        target = fz_page_number_from_location(ctx, d->doc, loc);
                }
                fz_catch(ctx) target = -1;
                if (target < 0)
                    continue;
            }
            exports_webby_pdf_documents_link_t *k = &ret->links.ptr[ret->links.len++];
            k->x0 = fin(l->rect.x0 - b.x0);
            k->y0 = fin(l->rect.y0 - b.y0);
            k->x1 = fin(l->rect.x1 - b.x0);
            k->y1 = fin(l->rect.y1 - b.y0);
            set_string(&k->uri, target >= 0 ? "" : l->uri);
            k->page = target;
            k->y = target >= 0 ? fin(ty) : 0;
        }
        ok = true;
    }
    fz_always(ctx)
    {
        fz_drop_link(ctx, links);
        fz_drop_stext_page(ctx, text);
        fz_drop_page(ctx, page);
    }
    fz_catch(ctx)
    {
        set_string(err, fz_caught_message(ctx));
        for (size_t i = 0; i < lines.len; i++)
            free(lines.ptr[i].ptr);
        free(lines.ptr);
        exports_webby_pdf_documents_list_link_free(&ret->links);
        memset(ret, 0, sizeof *ret);
        return false;
    }
    ret->lines.ptr = lines.ptr;
    ret->lines.len = lines.len;
    return ok;
}

/* wasi-libc has no mkstemp; MuPDF only names it for temporary files a stream-opened document never needs. */
__attribute__((weak)) int mkstemp(char *path)
{
    (void)path;
    errno = ENOTSUP;
    return -1;
}
