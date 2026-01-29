package main

import (
	"bufio"
	"fmt"
	"net/http"
	"strings"
)

func main() {
	resp, err := http.Get("https://publicsuffix.org/list/public_suffix_list.dat")
	if err != nil {
		panic(err)
	}
	defer resp.Body.Close()

	var domains []string

	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if len(line) == 0 || strings.HasPrefix(line, "//") {
			continue
		}

		domains = append(domains, line)
	}

	lookup :=
		"const std = @import(\"std\");\n" +
			"const builtin = @import(\"builtin\");\n\n" +
			"pub fn lookup(value: []const u8) bool {\n" +
			"    return public_suffix_list.has(value);\n" +
			"}\n"
	fmt.Println(lookup)

	fmt.Println("const public_suffix_list = std.StaticStringMap(void).initComptime(entries);\n")
	fmt.Println("const entries: []const struct { []const u8, void } =")
	fmt.Println("    if (builtin.is_test) &.{")
	fmt.Println("        .{ \"api.gov.uk\", {} },")
	fmt.Println("        .{ \"gov.uk\", {} },")
	fmt.Println("    } else &.{")
	for _, domain := range domains {
		fmt.Printf(`        .{ "%s", {} },`, domain)
		fmt.Println()
	}
	fmt.Println("    };")
}
