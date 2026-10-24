/* webby-pdf: renders one PDF with MuPDF for webby's PDF viewer (nim/src/features/pdf.nim).
 *
 * It's a separate program rather than a library webby links: a broken or hostile PDF can only crash this process,
 * and MuPDF (AGPL-3.0) stays out of the webby binary. Built, this program is under the AGPL-3.0 as MuPDF is; this
 * file itself is BSD-2-Clause like the rest of webby. webby talks to it over stdin/stdout:
 *
 *   requests, one per line, fields split by tabs:
 *     open <path>                     the document (once, first)
 *     render <page> <scale> <tag>     a page's pixels at `scale` pixels per point
 *     text <page>                     a page's characters and links
 *   answers, in order: one line of JSON; one that has "bytes": n is followed by n raw bytes.
 *     {"op":"open","ok":true,"pages":[[w,h],...],"title":"...","outline":[[level,"title",page,y],...]}
 *     {"op":"render","page":p,"tag":t,"w":W,"h":H,"bytes":W*H*4}  then premultiplied BGRA rows (cairo's ARGB32)
 *     {"op":"text","page":p,"lines":[[[x0,y0,x1,y1,codepoint],...],...],"links":[[x0,y0,x1,y1,"uri",page,y],...]}
 *     {"op":"...","ok":false,"error":"..."}
 *   Page sizes and positions are in points, from the page's top left. A link inside the document has page >= 0
 *   (and uri ""), an outside one page -1. */
#include <mupdf/fitz.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static fz_context *ctx;
static fz_document *doc;
static int npages;

static void put_string(FILE *f, const char *s) {
	fputc('"', f);
	for (const unsigned char *p = (const unsigned char *)(s ? s : ""); *p; p++) {
		if (*p == '"' || *p == '\\') fprintf(f, "\\%c", *p);
		else if (*p < 0x20) fprintf(f, "\\u%04x", *p);
		else fputc(*p, f);
	}
	fputc('"', f);
}

static void fail(const char *op, const char *msg) {
	printf("{\"op\":\"%s\",\"ok\":false,\"error\":", op);
	put_string(stdout, msg);
	printf("}\n");
	fflush(stdout);
}

static void put_outline(fz_outline *o, int level, int *first) {
	for (; o; o = o->next) {
		int page = o->page.page >= 0 ? fz_page_number_from_location(ctx, doc, o->page) : -1;
		printf("%s[%d,", *first ? "" : ",", level);
		*first = 0;
		put_string(stdout, o->title);
		printf(",%d,%.1f]", page, o->y);
		if (o->down) put_outline(o->down, level + 1, first);
	}
}

static void do_open(const char *path) {
	fz_outline *outline = NULL;
	fz_var(outline);
	fz_try(ctx) {
		doc = fz_open_document(ctx, path);
		if (fz_needs_password(ctx, doc) && !fz_authenticate_password(ctx, doc, ""))
			fz_throw(ctx, FZ_ERROR_GENERIC, "password protected");
		npages = fz_count_pages(ctx, doc);
		printf("{\"op\":\"open\",\"ok\":true,\"pages\":[");
		for (int i = 0; i < npages; i++) {
			fz_rect r = fz_empty_rect;
			fz_try(ctx) {
				fz_page *page = fz_load_page(ctx, doc, i);
				r = fz_bound_page(ctx, page);
				fz_drop_page(ctx, page);
			}
			fz_catch(ctx) r = fz_make_rect(0, 0, 612, 792);
			printf("%s[%.2f,%.2f]", i ? "," : "", r.x1 - r.x0, r.y1 - r.y0);
		}
		char title[1024] = "";
		fz_lookup_metadata(ctx, doc, FZ_META_INFO_TITLE, title, sizeof title);
		printf("],\"title\":");
		put_string(stdout, title);
		printf(",\"outline\":[");
		fz_try(ctx) outline = fz_load_outline(ctx, doc);
		fz_catch(ctx) outline = NULL;
		int first = 1;
		put_outline(outline, 0, &first);
		printf("]}\n");
		fflush(stdout);
	}
	fz_always(ctx) fz_drop_outline(ctx, outline);
	fz_catch(ctx) {
		doc = NULL;
		fail("open", fz_caught_message(ctx));
	}
}

static void do_render(int pageno, float scale, int tag) {
	fz_page *page = NULL;
	fz_pixmap *pix = NULL;
	fz_device *dev = NULL;
	fz_var(page); fz_var(pix); fz_var(dev);
	fz_try(ctx) {
		page = fz_load_page(ctx, doc, pageno);
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
		int stride = (int)fz_pixmap_stride(ctx, pix);
		unsigned char *s = fz_pixmap_samples(ctx, pix);
		printf("{\"op\":\"render\",\"page\":%d,\"tag\":%d,\"w\":%d,\"h\":%d,\"bytes\":%d}\n", pageno, tag, w, h, w * h * 4);
		for (int y = 0; y < h; y++) fwrite(s + (size_t)y * stride, 1, (size_t)w * 4, stdout);
		fflush(stdout);
	}
	fz_always(ctx) {
		fz_drop_device(ctx, dev);
		fz_drop_pixmap(ctx, pix);
		fz_drop_page(ctx, page);
	}
	fz_catch(ctx) {
		/* An answer still has to come, so webby stops waiting for this page. */
		printf("{\"op\":\"render\",\"page\":%d,\"tag\":%d,\"w\":0,\"h\":0,\"bytes\":0,\"error\":", pageno, tag);
		put_string(stdout, fz_caught_message(ctx));
		printf("}\n");
		fflush(stdout);
	}
}

static int first_line;

static void put_blocks(fz_stext_block *block, float x0, float y0) {
	for (; block; block = block->next) {
		if (block->type == FZ_STEXT_BLOCK_STRUCT) {
			if (block->u.s.down) put_blocks(block->u.s.down->first_block, x0, y0);
			continue;
		}
		if (block->type != FZ_STEXT_BLOCK_TEXT) continue;
		for (fz_stext_line *line = block->u.t.first_line; line; line = line->next) {
			if (!line->first_char) continue;
			printf("%s[", first_line ? "" : ",");
			first_line = 0;
			for (fz_stext_char *ch = line->first_char; ch; ch = ch->next) {
				fz_rect r = fz_rect_from_quad(ch->quad);
				printf("%s[%.1f,%.1f,%.1f,%.1f,%d]", ch == line->first_char ? "" : ",",
					r.x0 - x0, r.y0 - y0, r.x1 - x0, r.y1 - y0, ch->c);
			}
			printf("]");
		}
	}
}

static void do_text(int pageno) {
	fz_page *page = NULL;
	fz_stext_page *text = NULL;
	fz_link *links = NULL;
	fz_var(page); fz_var(text); fz_var(links);
	fz_try(ctx) {
		page = fz_load_page(ctx, doc, pageno);
		fz_rect b = fz_bound_page(ctx, page);
		fz_stext_options opts = { 0 };
		text = fz_new_stext_page_from_page(ctx, page, &opts);
		fz_try(ctx) links = fz_load_links(ctx, page);
		fz_catch(ctx) links = NULL;
		printf("{\"op\":\"text\",\"page\":%d,\"lines\":[", pageno);
		first_line = 1;
		put_blocks(text->first_block, b.x0, b.y0);
		printf("],\"links\":[");
		int first = 1;
		for (fz_link *l = links; l; l = l->next) {
			if (!l->uri) continue;
			int target = -1;
			float ty = 0;
			if (!fz_is_external_link(ctx, l->uri)) {
				fz_try(ctx) {
					float tx;
					fz_location loc = fz_resolve_link(ctx, doc, l->uri, &tx, &ty);
					if (loc.page >= 0) target = fz_page_number_from_location(ctx, doc, loc);
				}
				fz_catch(ctx) target = -1;
				if (target < 0) continue;
			}
			printf("%s[%.1f,%.1f,%.1f,%.1f,", first ? "" : ",", l->rect.x0 - b.x0, l->rect.y0 - b.y0,
				l->rect.x1 - b.x0, l->rect.y1 - b.y0);
			first = 0;
			put_string(stdout, target >= 0 ? "" : l->uri);
			printf(",%d,%.1f]", target, target >= 0 ? ty : 0);
		}
		printf("]}\n");
		fflush(stdout);
	}
	fz_always(ctx) {
		fz_drop_link(ctx, links);
		fz_drop_stext_page(ctx, text);
		fz_drop_page(ctx, page);
	}
	fz_catch(ctx) {
		printf("{\"op\":\"text\",\"page\":%d,\"lines\":[],\"links\":[],\"error\":", pageno);
		put_string(stdout, fz_caught_message(ctx));
		printf("}\n");
		fflush(stdout);
	}
}

int main(void) {
	ctx = fz_new_context(NULL, NULL, 256 << 20);
	if (!ctx) { fail("open", "cannot start MuPDF"); return 1; }
	fz_register_document_handlers(ctx);
	/* MuPDF's warnings about damaged files go to stderr, which webby doesn't read. */
	char *line = NULL;
	size_t cap = 0;
	ssize_t n;
	while ((n = getline(&line, &cap, stdin)) > 0) {
		if (line[n - 1] == '\n') line[--n] = 0;
		char *f[4] = { 0 };
		int nf = 0;
		for (char *p = line; nf < 4; nf++) {
			f[nf] = p;
			char *tab = strchr(p, '\t');
			if (!tab) { nf++; break; }
			*tab = 0;
			p = tab + 1;
		}
		if (!strcmp(f[0], "open") && nf >= 2) do_open(f[1]);
		else if (!doc) fail(f[0], "no document");
		else if (!strcmp(f[0], "render") && nf >= 4) {
			int p = atoi(f[1]);
			if (p >= 0 && p < npages) do_render(p, (float)atof(f[2]), atoi(f[3]));
			else fail("render", "no such page");
		} else if (!strcmp(f[0], "text") && nf >= 2) {
			int p = atoi(f[1]);
			if (p >= 0 && p < npages) do_text(p);
			else fail("text", "no such page");
		} else fail(f[0], "unknown request");
	}
	return 0;
}
