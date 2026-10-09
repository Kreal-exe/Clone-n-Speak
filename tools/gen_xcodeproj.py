#!/usr/bin/env python3
"""Generates CloneNSpeak.xcodeproj from the files in Sources/ and Resources/.

The canonical build is ./build.sh (clang only); this project is for people who prefer Xcode.
Re-run after adding or removing source files:  python3 tools/gen_xcodeproj.py
"""
import hashlib
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
NAME = "Clone'n'Speak"
FRAMEWORKS = ["Cocoa", "AVFAudio", "AVFoundation", "UniformTypeIdentifiers", "NaturalLanguage", "QuartzCore"]


def gid(tag):
    return hashlib.md5(tag.encode()).hexdigest()[:24].upper()


def main():
    srcs = sorted(p.name for p in (ROOT / "Sources").glob("*.m"))
    hdrs = sorted(p.name for p in (ROOT / "Sources").glob("*.h"))
    others = ["worker.py", "Info.plist", "CloneNSpeak.entitlements"]
    langs = sorted(p.stem for p in (ROOT / "Resources").glob("*.lproj"))
    tables = sorted({f.name for lp in (ROOT / "Resources").glob("*.lproj") for f in lp.glob("*.strings")})
    types = {".m": "sourcecode.c.objc", ".h": "sourcecode.c.h", ".py": "text.script.python",
             ".plist": "text.plist.xml", ".entitlements": "text.plist.entitlements"}

    objs, fref, bfile = [], {}, {}
    for f in srcs + hdrs + others:
        fref[f] = gid("ref" + f)
        objs.append(f'{fref[f]} = {{isa = PBXFileReference; lastKnownFileType = {types[pathlib.Path(f).suffix]}; path = "{f}"; sourceTree = "<group>"; }};')
    for f in srcs + ["worker.py"]:
        bfile[f] = gid("build" + f)
        objs.append(f"{bfile[f]} = {{isa = PBXBuildFile; fileRef = {fref[f]}; }};")

    # localized .strings tables → variant groups
    variant = {}
    for t in tables:
        variant[t] = gid("variant" + t)
        kids = []
        for lang in langs:
            if (ROOT / "Resources" / f"{lang}.lproj" / t).exists():
                r = gid(f"loc{lang}{t}")
                kids.append(r)
                objs.append(f'{r} = {{isa = PBXFileReference; lastKnownFileType = text.plist.strings; name = {lang}; path = "{lang}.lproj/{t}"; sourceTree = "<group>"; }};')
        objs.append(f'{variant[t]} = {{isa = PBXVariantGroup; children = ({", ".join(kids)}); name = "{t}"; sourceTree = "<group>"; }};')
        bfile[t] = gid("buildvar" + t)
        objs.append(f"{bfile[t]} = {{isa = PBXBuildFile; fileRef = {variant[t]}; }};")

    fw_refs, fw_builds = [], []
    for fw in FRAMEWORKS:
        r, b = gid("fwref" + fw), gid("fwb" + fw)
        fw_refs.append(r)
        fw_builds.append(b)
        objs.append(f"{r} = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = {fw}.framework; path = System/Library/Frameworks/{fw}.framework; sourceTree = SDKROOT; }};")
        objs.append(f"{b} = {{isa = PBXBuildFile; fileRef = {r}; }};")

    P = {k: gid(k) for k in ["project", "main", "src", "res", "prod", "fwg", "app", "target", "srcph", "resph",
                              "fwph", "iconph", "pcfg", "tcfg", "pdbg", "prel", "tdbg", "trel"]}
    objs.append(f'{P["app"]} = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "{NAME}.app"; sourceTree = BUILT_PRODUCTS_DIR; }};')
    objs.append(f'{P["src"]} = {{isa = PBXGroup; children = ({", ".join(fref[f] for f in srcs + hdrs + others)}); path = Sources; sourceTree = "<group>"; }};')
    objs.append(f'{P["res"]} = {{isa = PBXGroup; children = ({", ".join(variant.values())}); path = Resources; sourceTree = "<group>"; }};')
    objs.append(f'{P["fwg"]} = {{isa = PBXGroup; children = ({", ".join(fw_refs)}); name = Frameworks; sourceTree = "<group>"; }};')
    objs.append(f'{P["prod"]} = {{isa = PBXGroup; children = ({P["app"]}); name = Products; sourceTree = "<group>"; }};')
    objs.append(f'{P["main"]} = {{isa = PBXGroup; children = ({P["src"]}, {P["res"]}, {P["fwg"]}, {P["prod"]}); sourceTree = "<group>"; }};')
    objs.append(f'{P["srcph"]} = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({", ".join(bfile[f] for f in srcs)}); runOnlyForDeploymentPostprocessing = 0; }};')
    res_files = [bfile["worker.py"]] + [bfile[t] for t in tables]
    objs.append(f'{P["resph"]} = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({", ".join(res_files)}); runOnlyForDeploymentPostprocessing = 0; }};')
    objs.append(f'{P["fwph"]} = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({", ".join(fw_builds)}); runOnlyForDeploymentPostprocessing = 0; }};')
    script = ("set -e\\n"
              "clang -fobjc-arc -mmacosx-version-min=13.0 -framework Cocoa \\\"$SRCROOT/tools/make_icon.m\\\" -o \\\"$DERIVED_FILE_DIR/make_icon\\\"\\n"
              "\\\"$DERIVED_FILE_DIR/make_icon\\\" \\\"$DERIVED_FILE_DIR/icon.png\\\"\\n"
              "I=\\\"$DERIVED_FILE_DIR/AppIcon.iconset\\\"; mkdir -p \\\"$I\\\"\\n"
              "for s in 16 32 128 256 512; do sips -z $s $s \\\"$DERIVED_FILE_DIR/icon.png\\\" --out \\\"$I/icon_${s}x${s}.png\\\" >/dev/null; "
              "d=$((s*2)); sips -z $d $d \\\"$DERIVED_FILE_DIR/icon.png\\\" --out \\\"$I/icon_${s}x${s}@2x.png\\\" >/dev/null; done\\n"
              "iconutil -c icns \\\"$I\\\" -o \\\"$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/AppIcon.icns\\\"\\n")
    objs.append(f'{P["iconph"]} = {{isa = PBXShellScriptBuildPhase; buildActionMask = 2147483647; files = (); inputPaths = ("$(SRCROOT)/tools/make_icon.m"); name = "App Icon"; outputPaths = ("$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/AppIcon.icns"); runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/zsh; shellScript = "{script}"; }};')
    objs.append(f'{P["target"]} = {{isa = PBXNativeTarget; buildConfigurationList = {P["tcfg"]}; buildPhases = ({P["srcph"]}, {P["fwph"]}, {P["resph"]}, {P["iconph"]}); buildRules = (); dependencies = (); name = "{NAME}"; productName = "{NAME}"; productReference = {P["app"]}; productType = "com.apple.product-type.application"; }};')
    common = "ARCHS = arm64; MACOSX_DEPLOYMENT_TARGET = 13.0; SDKROOT = macosx; CLANG_ENABLE_OBJC_ARC = YES; GCC_TREAT_WARNINGS_AS_ERRORS = YES;"
    objs.append(f'{P["pdbg"]} = {{isa = XCBuildConfiguration; buildSettings = {{{common} ONLY_ACTIVE_ARCH = YES; GCC_OPTIMIZATION_LEVEL = 0; }}; name = Debug; }};')
    objs.append(f'{P["prel"]} = {{isa = XCBuildConfiguration; buildSettings = {{{common} }}; name = Release; }};')
    tset = ('INFOPLIST_FILE = Sources/Info.plist; PRODUCT_BUNDLE_IDENTIFIER = com.clonenspeak.mac; '
            f'PRODUCT_NAME = "{NAME}"; CODE_SIGN_ENTITLEMENTS = Sources/CloneNSpeak.entitlements; '
            'CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; ENABLE_HARDENED_RUNTIME = YES; GENERATE_INFOPLIST_FILE = NO;')
    objs.append(f'{P["tdbg"]} = {{isa = XCBuildConfiguration; buildSettings = {{{tset} }}; name = Debug; }};')
    objs.append(f'{P["trel"]} = {{isa = XCBuildConfiguration; buildSettings = {{{tset} }}; name = Release; }};')
    objs.append(f'{P["pcfg"]} = {{isa = XCConfigurationList; buildConfigurations = ({P["pdbg"]}, {P["prel"]}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};')
    objs.append(f'{P["tcfg"]} = {{isa = XCConfigurationList; buildConfigurations = ({P["tdbg"]}, {P["trel"]}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};')
    known = ", ".join(sorted(set(langs + ["Base"])))
    objs.append(f'{P["project"]} = {{isa = PBXProject; attributes = {{LastUpgradeCheck = 1600; }}; buildConfigurationList = {P["pcfg"]}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = ({known}); mainGroup = {P["main"]}; productRefGroup = {P["prod"]}; projectDirPath = ""; projectRoot = ""; targets = ({P["target"]}); }};')

    body = "\n".join("\t\t" + o for o in objs)
    out = f"// !$*UTF8*$!\n{{\n\tarchiveVersion = 1;\n\tclasses = {{}};\n\tobjectVersion = 56;\n\tobjects = {{\n{body}\n\t}};\n\trootObject = {P['project']};\n}}\n"
    proj = ROOT / "CloneNSpeak.xcodeproj"
    proj.mkdir(exist_ok=True)
    (proj / "project.pbxproj").write_text(out, encoding="utf-8")
    print(f"wrote {proj.relative_to(ROOT)}/project.pbxproj ({len(srcs)} sources, {len(tables)} localized tables)")


if __name__ == "__main__":
    main()
