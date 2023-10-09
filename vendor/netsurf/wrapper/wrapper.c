#include <stdio.h>
#include <string.h>

#include <dom/dom.h>
#include <dom/bindings/hubbub/parser.h>

/**
 * Generate a LibDOM document DOM from an HTML string
 *
 * \param string The HTML string
 * \return  pointer to DOM document, or NULL on error
 */
dom_document *wr_create_doc_dom_from_string(const char *html)
{
	dom_hubbub_parser *parser = NULL;
	dom_hubbub_error error;
	dom_hubbub_parser_params params;
	dom_document *doc;

	params.enc = NULL;
	params.fix_enc = true;
	params.enable_script = false;
	params.msg = NULL;
	params.script = NULL;
	params.ctx = NULL;
	params.daf = NULL;

	/* Create Hubbub parser */
	error = dom_hubbub_parser_create(&params, &parser, &doc);
	if (error != DOM_HUBBUB_OK) {
		printf("Can't create Hubbub Parser\n");
		return NULL;
	}

	error = dom_hubbub_parser_parse_chunk(parser, html, strlen(html));
	if (error != DOM_HUBBUB_OK) {
		dom_hubbub_parser_destroy(parser);
		printf("Parsing errors occur\n");
		return NULL;
	}

	/* Done parsing file */
	error = dom_hubbub_parser_completed(parser);
	if (error != DOM_HUBBUB_OK) {
		dom_hubbub_parser_destroy(parser);
		printf("Parsing error when construct DOM\n");
		return NULL;
	}

	/* Finished with parser */
	dom_hubbub_parser_destroy(parser);

	return doc;
}

/**
 * Generate a LibDOM document DOM from an HTML file
 *
 * \param file  The file path
 * \return  pointer to DOM document, or NULL on error
 */
dom_document *wr_create_doc_dom_from_file(const char *filename)
{
	size_t buffer_size = 1024;
	dom_hubbub_parser *parser = NULL;
	FILE *handle;
	int chunk_length;
	dom_hubbub_error error;
	dom_hubbub_parser_params params;
	dom_document *doc;
	unsigned char buffer[buffer_size];

	params.enc = NULL;
	params.fix_enc = true;
	params.enable_script = false;
	params.msg = NULL;
	params.script = NULL;
	params.ctx = NULL;
	params.daf = NULL;

	/* Create Hubbub parser */
	error = dom_hubbub_parser_create(&params, &parser, &doc);
	if (error != DOM_HUBBUB_OK) {
		printf("Can't create Hubbub Parser\n");
		return NULL;
	}

	/* Open input file */
	handle = fopen(filename, "rb");
	if (handle == NULL) {
		dom_hubbub_parser_destroy(parser);
		printf("Can't open test input file: %s\n", filename);
		return NULL;
	}

	/* Parse input file in chunks */
	chunk_length = buffer_size;
	while (chunk_length == buffer_size) {
		chunk_length = fread(buffer, 1, buffer_size, handle);
		error = dom_hubbub_parser_parse_chunk(parser, buffer,
				chunk_length);
		if (error != DOM_HUBBUB_OK) {
			dom_hubbub_parser_destroy(parser);
			printf("Parsing errors occur\n");
			return NULL;
		}
	}

	/* Done parsing file */
	error = dom_hubbub_parser_completed(parser);
	if (error != DOM_HUBBUB_OK) {
		dom_hubbub_parser_destroy(parser);
		printf("Parsing error when construct DOM\n");
		return NULL;
	}

	/* Finished with parser */
	dom_hubbub_parser_destroy(parser);

	/* Close input file */
	if (fclose(handle) != 0) {
	  printf("Can't close test input file: %s\n", filename);
		return NULL;
	}

	return doc;
}
