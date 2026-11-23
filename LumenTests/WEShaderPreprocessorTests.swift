import XCTest

final class WEShaderPreprocessorTests: XCTestCase {
    func testChoosesOneConditionalBranchAndTracksUndefinitions() {
        var preprocessor = WEShaderPreprocessor(defines: ["MODE": "2"]) { _ in nil }
        let output = preprocessor.process(#"""
        #version 330
        #define LEVEL (1 + 2 * 3)
        #if MODE == 0
        disabled
        #elif MODE == 2 && \
              defined(LEVEL) && LEVEL == 7 // chosen combo
        active
        #ifdef UNSET
        nestedDisabled
        #else
        nestedActive
        #endif
        #elif MODE == 2
        secondMatch
        #else
        fallback
        #endif
        #undef LEVEL
        #ifndef LEVEL
        afterUndef
        #endif
        """#)

        XCTAssertEqual(output.split(separator: "\n").map(String.init), [
            "#define LEVEL (1 + 2 * 3)", "active", "nestedActive", "#undef LEVEL", "afterUndef"
        ])
        XCTAssertEqual(preprocessor.emittedMacros, ["LEVEL"])
        XCTAssertNil(preprocessor.defines["LEVEL"])
    }

    func testExpandsActiveIncludesOnceEvenWhenTheyFormACycle() {
        let includes = [
            "common.h": "#define FLAG 1\n#include <nested.h>\ncommon",
            "nested.h": "#include \"common.h\"\nnested",
        ]
        var requested: [String] = []
        var preprocessor = WEShaderPreprocessor(defines: [:]) { name in
            requested.append(name)
            return includes[name]
        }
        let output = preprocessor.process(#"""
        /* #include "commented.h" */
        #if 0
        #include "disabled.h"
        #endif
        #include "common.h"
        #include <nested.h>
        #if FLAG
        root
        #endif
        """#)

        XCTAssertEqual(requested, ["common.h", "nested.h"])
        XCTAssertEqual(output.split(separator: "\n").map(String.init), ["#define FLAG 1", "nested", "common", "root"])
    }
}
