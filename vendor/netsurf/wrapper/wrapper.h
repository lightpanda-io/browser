#ifndef wrapper_dom_h_
#define wrapper_dom_h_

#include <dom/dom.h>

dom_document *wr_create_doc_dom_from_string(char *html);
dom_document *wr_create_doc_dom_from_file(char *filename);

#endif	/* wrapper_dom_h_ */
