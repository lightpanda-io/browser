/* Drive the browser through the tool surface from a program: a structured
 * session, so failures are statuses and results are JSON where the tool can
 * produce it. Navigate, read where the page landed, evaluate a script, then
 * extract the title and links via a selector schema.
 *
 * Build from the repo root after `make lib`, with the link line
 * documented in include/lightpanda.h. Run:
 *   ./tools https://example.com
 */

#include <lightpanda.h>
#include <stdio.h>
#include <string.h>

static lp_status call(lp_session *session, const char *tool, const char *args, lp_result *result) {
    lp_status status = lp_call(session, tool, strlen(tool), args, args ? strlen(args) : 0, result);
    if (status != LP_OK) {
        /* Every failure carries its message in the result. */
        fprintf(stderr, "%s failed: %d: %.*s\n", tool, status, (int)result->len, result->text ? result->text : "");
    }
    return status;
}

int main(int argc, char **argv) {
    const char *url = argc > 1 ? argv[1] : "https://example.com";

    lp_browser *browser = NULL;
    if (lp_init(NULL, 0, &browser) != LP_OK) {
        fprintf(stderr, "lp_init failed\n");
        return 1;
    }

    lp_session *session = NULL;
    if (lp_session_new(browser, LP_OPTS(lp_session_opts, .structured = 1), &session) != LP_OK) {
        fprintf(stderr, "lp_session_new failed\n");
        lp_shutdown(browser);
        return 1;
    }

    lp_result result = {0};
    char args[1024];
    snprintf(args, sizeof args, "{\"url\":\"%s\"}", url);
    lp_status status = call(session, "goto", args, &result);
    if (status != LP_OK) goto done;

    lp_page_state page = {0};
    status = lp_session_page_state(session, &page, sizeof page);
    if (status != LP_OK) goto done;
    printf("--- goto ---\n%.*s (HTTP %llu): %.*s\n", (int)page.url.len, page.url.ptr,
           (unsigned long long)page.http_status, (int)page.title.len, page.title.ptr ? page.title.ptr : "");

    /* evaluate's value comes back as JSON. */
    status = call(session, "evaluate", "{\"script\":\"document.links.length\"}", &result);
    if (status != LP_OK) goto done;
    printf("--- evaluate ---\n%.*s links\n", (int)result.len, result.text);

    /* extract's "schema" argument is a string holding a JSON object literal
     * that maps output fields to CSS-selector specs (not a JSON Schema). */
    status = call(session, "extract",
                  "{\"schema\":"
                  "\"{\\\"title\\\": \\\"title\\\","
                  " \\\"links\\\": [{\\\"selector\\\": \\\"a\\\", \\\"attr\\\": \\\"href\\\"}]}\""
                  "}",
                  &result);
    if (status != LP_OK) goto done;
    printf("--- extract ---\n%.*s\n", (int)result.len, result.text);

done:
    lp_session_close(session);
    lp_shutdown(browser);
    return status == LP_OK ? 0 : 1;
}
