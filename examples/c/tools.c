/* Drive the browser through the tool surface: navigate, then extract the
 * page title and links via a selector schema.
 *
 * Build from the repo root after `make lib`, with the link line
 * documented in include/lightpanda.h. Run:
 *   ./tools https://example.com
 */

#include <lightpanda.h>
#include <stdio.h>
#include <string.h>

static lp_status call(lp_session *session, const char *tool, const char *args) {
    lp_result result = {0};
    lp_status status = lp_call(session, tool, strlen(tool), args, args ? strlen(args) : 0, &result);
    if (status != LP_OK) {
        fprintf(stderr, "%s failed: %d\n", tool, status);
        return status;
    }
    printf("--- %s%s ---\n%.*s\n", tool, result.is_error ? " (page error)" : "", (int)result.len, result.text);
    return LP_OK;
}

int main(int argc, char **argv) {
    const char *url = argc > 1 ? argv[1] : "https://example.com";

    lp_browser *browser = NULL;
    if (lp_init(NULL, &browser) != LP_OK) {
        fprintf(stderr, "lp_init failed\n");
        return 1;
    }

    lp_session *session = NULL;
    if (lp_session_new(browser, &session) != LP_OK) {
        fprintf(stderr, "lp_session_new failed\n");
        lp_shutdown(browser);
        return 1;
    }

    char args[1024];
    snprintf(args, sizeof args, "{\"url\":\"%s\"}", url);
    lp_status status = call(session, "goto", args);

    /* extract's "schema" argument is a string holding a JSON object literal
     * that maps output fields to CSS-selector specs (not a JSON Schema). */
    if (status == LP_OK)
        status = call(session, "extract",
                      "{\"schema\":"
                      "\"{\\\"title\\\": \\\"title\\\","
                      " \\\"links\\\": [{\\\"selector\\\": \\\"a\\\", \\\"attr\\\": \\\"href\\\"}]}\""
                      "}");
    if (status == LP_OK)
        status = call(session, "getUrl", NULL);

    lp_session_close(session);
    lp_shutdown(browser);
    return status == LP_OK ? 0 : 1;
}
