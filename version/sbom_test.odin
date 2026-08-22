package version

import "core:os"
import "core:strings"
import "core:testing"

SBOM_TEMPLATE_PATH :: #directory + "../scripts/sbom.spdx.json.in"
DEPENDENCIES_PATH :: #directory + "../docs/DEPENDENCIES.md"

@(test)
test_sbom_template_matches_dependency_inventory :: proc(t: ^testing.T) {
	template, terr := os.read_entire_file(SBOM_TEMPLATE_PATH, context.allocator)
	testing.expect_value(t, terr, nil)
	defer delete(template)
	deps, derr := os.read_entire_file(DEPENDENCIES_PATH, context.allocator)
	testing.expect_value(t, derr, nil)
	defer delete(deps)

	template_text := string(template)
	deps_text := string(deps)

	testing.expect(t, strings.contains(template_text, "SPDX-2.3"))
	testing.expect(t, strings.contains(template_text, `"name": "thirp-runtime"`))
	testing.expect(t, strings.contains(template_text, `"name": "OpenSSL"`))
	testing.expect(t, strings.contains(template_text, "Apache-2.0"))
	testing.expect(t, strings.contains(template_text, `"relationshipType": "DEPENDS_ON"`))
	testing.expect(t, strings.contains(template_text, "SPDXRef-Package-thirp-runtime"))
	testing.expect(t, strings.contains(template_text, "SPDXRef-Package-openssl"))

	testing.expect(t, strings.contains(deps_text, "OpenSSL"))
	testing.expect(t, strings.contains(deps_text, "Apache-2.0"))
	testing.expect(t, strings.contains(deps_text, "dev-2026-07"))

	testing.expect(t, !strings.contains(template_text, "change-me"))
	testing.expect(t, !strings.contains(template_text, "token="))
	testing.expect(t, !strings.contains(deps_text, "change-me"))
}
