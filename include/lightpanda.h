#ifndef _LIGHTPANDA_H
#define _LIGHTPANDA_H

void* lightpanda_app_init();
void lightpanda_app_deinit(void* app_ptr);

void* lightpanda_browser_init(void* app_ptr);
void lightpanda_browser_deinit(void* browser_ptr);

void* lightpanda_browser_new_session(void* browser_ptr);

void* lightpanda_session_create_page(void* session_ptr);

void lightpanda_page_navigate(void* page_ptr, const char *url);

void* lightpanda_cdp_init(void* app_ptr, void (*handler_fn)(void*, const char *), void* ctx);
void lightpanda_cdp_deinit(void* cdp_ptr);
const char* lightpanda_cdp_create_browser_context(void* cdp_ptr);
void* lightpanda_cdp_browser(void* cdp_ptr);
void lightpanda_cdp_process_message(void* cdp_ptr, const char *msg);
void* lightpanda_cdp_browser_context(void* cdp_ptr);
void* lightpanda_browser_context_session(void* browser_context_ptr);

#endif