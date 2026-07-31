/* Fetch a page and print it as markdown.
 *
 * Build from the repo root after `make lib`, with the link line
 * documented in include/lightpanda.h. Run:
 *   ./fetch https://example.com
 */

#include <lightpanda.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <url>\n", argv[0]);
        return 2;
    }

    lp_browser *browser = NULL;
    lp_status status = lp_init(NULL, &browser);
    if (status != LP_OK) {
        fprintf(stderr, "lp_init failed: %d\n", status);
        return 1;
    }

    lp_fetch_opts opts = {0};
    opts.format = LP_FORMAT_MARKDOWN;

    lp_result result = {0};
    status = lp_fetch(browser, argv[1], &opts, &result);
    if (status != LP_OK) {
        fprintf(stderr, "lp_fetch failed: %d\n", status);
        lp_shutdown(browser);
        return 1;
    }

    /* result.text is library-owned: valid until the next lp_fetch on this
     * browser or lp_shutdown. */
    fwrite(result.text, 1, result.len, stdout);
    lp_shutdown(browser);
    return 0;
}
