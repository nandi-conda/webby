# webby's Qt UI as one latha:gui WebAssembly component: QtGui chrome (BrowserWindow) and Ladybird's LibWeb (WebView)
# in one module (webby-ui), and the engine alone as a component of its own (webby-core, wit/engine/engine.wit) for
# the UI component that shell/ builds without Ladybird (wac plug composes the two). Built inside Ladybird's WASI build (ENABLE_GUI_TARGETS=ON) when WEBBY_UI_DIR names this directory:
# Utilities/CMakeLists.txt (wasm/patches/0014) adds it; it shares webby-render's Compositor sources.
#
# Qt for WASI and the qt2wasm GUI pieces come from the wasm/ pixi env (qt2wasm, qt6-wasi, wit-bindgen, wasm-tools,
# wasi-preview1-adapter): WEBBY_QT_ENV, which defaults to the env that holds $WASI_SDK_PREFIX. This is what
# `qt2wasm build --gui` does (Qt2Wasm.cmake, qt2wasm/build.py), spelled out so that it can live in Ladybird's build.
#
# Output: bin/webby-ui.core.wasm (the reactor module, after the build's spill-pointers pass) and bin/webby.wasm (the
# component a latha:gui host runs); bin/webby-core.wasm (the engine component, target webby-core).

cmake_minimum_required(VERSION 3.25)

if (NOT WEBBY_QT_ENV AND DEFINED ENV{WEBBY_QT_ENV})
    set(WEBBY_QT_ENV "$ENV{WEBBY_QT_ENV}")
endif()
if (NOT WEBBY_QT_ENV)
    get_filename_component(WEBBY_QT_ENV "$ENV{WASI_SDK_PREFIX}/../.." ABSOLUTE)
endif()
set(qt "${WEBBY_QT_ENV}/opt/qt6-wasi/wasi")
set(qt_version 6.8.3)
file(GLOB qt2wasm_data LIST_DIRECTORIES true "${WEBBY_QT_ENV}/lib/python3*/site-packages/qt2wasm/_data")
if (NOT EXISTS "${qt}/lib/libQt6Gui.a" OR NOT qt2wasm_data)
    message(WARNING "webby-ui: no Qt for WASI or qt2wasm in WEBBY_QT_ENV=${WEBBY_QT_ENV} (pixi install in wasm/); not building the UI")
    return()
endif()
set(moc "${WEBBY_QT_ENV}/opt/qt6-wasi/host/libexec/moc")
find_program(WIT_BINDGEN wit-bindgen HINTS "${WEBBY_QT_ENV}/bin" REQUIRED)
find_program(WASM_TOOLS wasm-tools HINTS "${WEBBY_QT_ENV}/bin" REQUIRED)
set(adapter "${WEBBY_QT_ENV}/share/wasi-preview1-adapter/wasi_snapshot_preview1.reactor.wasm")
set(gen "${CMAKE_CURRENT_BINARY_DIR}/gen")
file(MAKE_DIRECTORY "${gen}/bindings")

# moc, for this UI and for qt2wasm's runtime (its event dispatcher) and GUI platform plugin.
set(moc_outputs)
foreach (header "${CMAKE_CURRENT_SOURCE_DIR}/BrowserWindow.h" "${qt2wasm_data}/runtime/wasieventdispatcher.h" "${qt2wasm_data}/gui/qt2wasmgui.h")
    get_filename_component(name "${header}" NAME_WE)
    add_custom_command(OUTPUT "${gen}/moc_${name}.cpp" COMMAND "${moc}" "${header}" -o "${gen}/moc_${name}.cpp"
        DEPENDS "${header}" VERBATIM)
    list(APPEND moc_outputs "${gen}/moc_${name}.cpp")
endforeach()

# The latha:gui world's C bindings (exports app, imports host), which qt2wasmgui.cpp implements.
# The app's world (wit/app): latha:gui plus webby:pdf's documents (MuPDF, the webby-pdf component below).
set(pdf_dir "${CMAKE_CURRENT_SOURCE_DIR}/../pdf")
set(app_wit "${CMAKE_CURRENT_SOURCE_DIR}/wit/app/app.wit" "${qt2wasm_data}/gui/wit/gui.wit" "${pdf_dir}/wit/pdf.wit")
add_custom_command(OUTPUT "${gen}/bindings/gui.c" "${gen}/bindings/gui.h" "${gen}/bindings/gui_component_type.o"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${gen}/wit"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${gen}/wit/deps/gui" "${gen}/wit/deps/pdf"
    COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_CURRENT_SOURCE_DIR}/wit/app/app.wit" "${gen}/wit/"
    COMMAND ${CMAKE_COMMAND} -E copy "${qt2wasm_data}/gui/wit/gui.wit" "${gen}/wit/deps/gui/"
    COMMAND ${CMAKE_COMMAND} -E copy "${pdf_dir}/wit/pdf.wit" "${gen}/wit/deps/pdf/"
    COMMAND "${WIT_BINDGEN}" c "${gen}/wit" --world gui --out-dir "${gen}/bindings"
    DEPENDS ${app_wit} VERBATIM)

# webby-pdf.wasm: MuPDF (deps/mupdf.sh, in the sysroot's mupdf/) behind webby:pdf (../pdf). It is compiled here with
# wasi-sdk's clang directly, not as a CMake target of this build: none of Ladybird's flags, compat library or
# --spill-pointers pass apply to it, and it links MuPDF's own FreeType/HarfBuzz/zlib/libjpeg, which live in this
# component alone. AGPL-3.0, as MuPDF is.
set(mupdf "$ENV{WEBBY_WASI_SYSROOT}/mupdf")
set(pdf_core "${CMAKE_BINARY_DIR}/bin/webby-pdf.core.wasm")
set(pdf_component "${CMAKE_BINARY_DIR}/bin/webby-pdf.wasm")
add_custom_command(OUTPUT "${gen}/pdf/pdf.c" "${gen}/pdf/pdf.h" "${gen}/pdf/pdf_component_type.o"
    COMMAND "${WIT_BINDGEN}" c "${pdf_dir}/wit" --world pdf --out-dir "${gen}/pdf"
    DEPENDS "${pdf_dir}/wit/pdf.wit" VERBATIM)
if (EXISTS "${mupdf}/lib/libmupdf.a")
    set(pdf_flags --target=wasm32-wasip1 -O2 -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false)
    add_custom_command(OUTPUT "${pdf_component}"
        COMMAND "${CMAKE_C_COMPILER}" ${pdf_flags} -I "${gen}/pdf" -I "${mupdf}/include" -Wall
            "${pdf_dir}/webby_pdf.c" "${gen}/pdf/pdf.c" "${gen}/pdf/pdf_component_type.o"
            "${mupdf}/lib/libmupdf.a" "${mupdf}/lib/libmupdf-third.a" -lsetjmp -lm -mexec-model=reactor
            -Wl,--gc-sections -o "${pdf_core}"
        COMMAND "${WASM_TOOLS}" component new "${pdf_core}" --adapt "wasi_snapshot_preview1=${adapter}" -o "${pdf_component}"
        DEPENDS "${pdf_dir}/webby_pdf.c" "${gen}/pdf/pdf.c" "${mupdf}/lib/libmupdf.a" "${mupdf}/lib/libmupdf-third.a"
        COMMENT "Making the PDF component bin/webby-pdf.wasm" VERBATIM)
else()
    add_custom_command(OUTPUT "${pdf_component}"
        COMMAND ${CMAKE_COMMAND} -E echo "webby-pdf: no MuPDF in ${mupdf} (wasm/deps/mupdf.sh; the wasm-deps sysroot has it)"
        COMMAND false VERBATIM)
endif()
add_custom_target(webby-pdf DEPENDS "${pdf_component}")

# wac composes webby.wasm from the UI's component and webby-pdf.wasm: $WAC, else on PATH, else downloaded here.
if (DEFINED ENV{WAC} AND EXISTS "$ENV{WAC}")
    set(WAC "$ENV{WAC}")
else()
    find_program(WAC wac)
endif()
if (NOT WAC)
    set(WAC "${CMAKE_BINARY_DIR}/tools/wac-0.8.1")
    if (NOT EXISTS "${WAC}")
        file(DOWNLOAD https://github.com/bytecodealliance/wac/releases/download/v0.8.1/wac-cli-x86_64-unknown-linux-musl "${WAC}")
        file(CHMOD "${WAC}" PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)
    endif()
endif()

set(compositor_dir ${LADYBIRD_SOURCE_DIR}/Services/Compositor)

# WebGL on the host's GPU (../gl): the Compositor's WebGL code (CanvasHost down to OpenGLContext) runs in the module,
# behind LibWeb's local WebGL transport (LocalWebGL.cpp), and its GLES and EGL calls go to latha:gui's gl interface.
# A host without it (no LATHA_GUI_GL in the environment) gets no WebGL contexts, as before.
set(webby_gl_dir "${CMAKE_CURRENT_SOURCE_DIR}/../gl")
add_custom_command(OUTPUT "${gen}/gl/gl_guest.c" "${gen}/gl/gl_guest.h" "${gen}/gl/gl_guest_component_type.o"
    COMMAND "${WIT_BINDGEN}" c "${webby_gl_dir}/wit" --world gl-guest --out-dir "${gen}/gl"
    DEPENDS "${webby_gl_dir}/wit/gl.wit" VERBATIM)
set(webgl_generated "${CMAKE_BINARY_DIR}/Libraries/LibCompositing/WebGL/GLFunctions.cpp" "${CMAKE_BINARY_DIR}/Services/Compositor/WebGLCommandReplayer.cpp")
set_source_files_properties(${webgl_generated} PROPERTIES GENERATED TRUE)
add_library(webby-webgl STATIC
    LocalWebGL.cpp
    ${compositor_dir}/BitmapExport.cpp
    ${compositor_dir}/CanvasHost.cpp
    ${compositor_dir}/HostWebGLContext.cpp
    ${compositor_dir}/OpenGLContext.cpp
    ${compositor_dir}/VideoFrameHolds.cpp
    ${compositor_dir}/WebGLObjectMap.cpp
    ${webgl_generated}
    "${webby_gl_dir}/latha_gles.c"
    "${webby_gl_dir}/latha_gles_custom.c"
    "${webby_gl_dir}/latha_egl.c"
    "${gen}/gl/gl_guest.c")
add_dependencies(webby-webgl generate_GLFunctions.cpp generate_WebGLCommandReplayer.cpp)
# EGL's native types are plain pointers here (eglplatform.h knows no WASI).
set_source_files_properties("${CMAKE_BINARY_DIR}/Libraries/LibCompositing/WebGL/GLFunctions.cpp" PROPERTIES
    COMPILE_OPTIONS "-include;${webby_gl_dir}/angle_compat.h")
target_compile_definitions(webby-webgl PRIVATE EGL_NO_PLATFORM_SPECIFIC_TYPES)
target_include_directories(webby-webgl PRIVATE ${LADYBIRD_SOURCE_DIR}/Services ${CMAKE_BINARY_DIR}/Services
    "${CMAKE_CURRENT_SOURCE_DIR}" "${webby_gl_dir}" "${gen}/gl")
# Only LibWeb (and ANGLE's headers): naming skia here would put it ahead of libpng in the link line, and Qt's PNG
# handler would take skia's copy of libpng next to the engine's own.
target_link_libraries(webby-webgl PUBLIC "${gen}/gl/gl_guest_component_type.o" ${ANGLE_TARGETS} LibWeb)
target_include_directories(webby-webgl SYSTEM PRIVATE $<TARGET_PROPERTY:skia,INTERFACE_INCLUDE_DIRECTORIES>)
target_compile_definitions(webby-webgl PRIVATE $<TARGET_PROPERTY:skia,INTERFACE_COMPILE_DEFINITIONS>)
set_source_files_properties("${webby_gl_dir}/latha_gles.c" "${webby_gl_dir}/latha_gles_custom.c" "${webby_gl_dir}/latha_egl.c"
    "${gen}/gl/gl_guest.c" PROPERTIES COMPILE_OPTIONS "-w;-Wno-error")
# Passwords and passkeys: the Nim front end's passkey authenticator (../../native/Authenticator.cpp, with its
# CredentialStore) and page script (../../nim/src/scripts/passwords.js); latha:gui's pty interface for the keyring
# lookup (Keyring.cpp, wit/pty). WEBBY_NATIVE_DIR and WEBBY_SCRIPTS_DIR override where they are (the forge CI keeps
# copies beside its copy of wasm/ui).
if (NOT WEBBY_NATIVE_DIR)
    get_filename_component(WEBBY_NATIVE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../native" ABSOLUTE)
endif()
if (NOT WEBBY_SCRIPTS_DIR)
    get_filename_component(WEBBY_SCRIPTS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../nim/src/scripts" ABSOLUTE)
endif()
add_custom_command(OUTPUT "${gen}/pty/pty_guest.c" "${gen}/pty/pty_guest.h" "${gen}/pty/pty_guest_component_type.o"
    COMMAND "${WIT_BINDGEN}" c "${CMAKE_CURRENT_SOURCE_DIR}/wit/pty" --world pty-guest --out-dir "${gen}/pty"
    DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/wit/pty/pty.wit" VERBATIM)
set_source_files_properties(PageScripts.c PROPERTIES COMPILE_OPTIONS "-std=c23;--embed-dir=${WEBBY_SCRIPTS_DIR}"
    OBJECT_DEPENDS "${WEBBY_SCRIPTS_DIR}/passwords.js")
set_source_files_properties("${gen}/pty/pty_guest.c" "${WEBBY_NATIVE_DIR}/Authenticator.cpp" PROPERTIES COMPILE_OPTIONS "-w;-Wno-error")

add_executable(webby-ui
    BrowserWindow.cpp
    Dialog.cpp
    Keyring.cpp
    PageScripts.c
    PasskeyStore.cpp
    PasswordBar.cpp
    Passwords.cpp
    Vault.cpp
    "${WEBBY_NATIVE_DIR}/Authenticator.cpp"
    "${gen}/pty/pty_guest.c"
    PageMenu.cpp
    PopupMenu.cpp
    KeyMap.cpp
    Network.cpp
    MoreMenu.cpp
    Storage.cpp
    Omnibox.cpp
    PageFrame.cpp
    Pages.cpp
    PdfView.cpp
    Profile.cpp
    Resources.c
    Sessions.cpp
    SessionsPage.cpp
    Sync.cpp
    SyncDoc.cpp
    SyncKeys.cpp
    SyncPages.cpp
    WebView.cpp
    main.cpp
    qt_wasi_shims.c
    ${moc_outputs}
    "${gen}/bindings/gui.c"
    "${qt2wasm_data}/runtime/runtime.cpp"
    "${qt2wasm_data}/runtime/wasieventdispatcher.cpp"
    "${qt2wasm_data}/gui/qt2wasmgui.cpp"
    ${compositor_dir}/Canvas2DCommandPlayer.cpp
    ${compositor_dir}/ColorSpaceSkia.cpp
    ${compositor_dir}/DisplayListPlayer.cpp
    ${compositor_dir}/DisplayListPlayerSkia.cpp
    ${compositor_dir}/DisplayListRasterCache.cpp
    ${compositor_dir}/FontSkia.cpp
    ${compositor_dir}/PainterSkia.cpp
    ${compositor_dir}/PaintingSurface.cpp
    ${compositor_dir}/RasterizeDisplayList.cpp
    ${compositor_dir}/ScrollbarController.cpp
    ${compositor_dir}/SkiaBackendContext.cpp
    ${compositor_dir}/SkiaUtils.cpp
    ${compositor_dir}/VideoFrameSkia.cpp)
# Built in (Resources.c, #embed): Ladybird's default theme and the Liberation fonts.
set_source_files_properties(Resources.c PROPERTIES COMPILE_OPTIONS
    "-std=c23;--embed-dir=${CMAKE_CURRENT_SOURCE_DIR}/fonts;--embed-dir=${LADYBIRD_SOURCE_DIR}/Base/res/themes"
    OBJECT_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/fonts/LiberationSans-Regular.ttf;${LADYBIRD_SOURCE_DIR}/Base/res/themes/Default.ini")
set_target_properties(webby-ui PROPERTIES SUFFIX ".core.wasm" RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
target_include_directories(webby-ui PRIVATE
    ${LADYBIRD_SOURCE_DIR}/Services ${CMAKE_BINARY_DIR}/Services
    "${CMAKE_CURRENT_SOURCE_DIR}" "${gen}/bindings" "${gen}/pty" "${WEBBY_NATIVE_DIR}"
    "${qt2wasm_data}/include" "${qt2wasm_data}/runtime" "${qt2wasm_data}/gui"
    "${qt}/include" "${qt}/include/QtCore" "${qt}/include/QtGui" "${qt}/mkspecs/wasi-clang"
    "${qt}/include/QtCore/${qt_version}" "${qt}/include/QtCore/${qt_version}/QtCore"
    "${qt}/include/QtGui/${qt_version}" "${qt}/include/QtGui/${qt_version}/QtGui")
target_compile_definitions(webby-ui PRIVATE QT_CORE_LIB QT_GUI_LIB QT_NO_DEBUG QT_STATIC QT_STATICPLUGIN
    QT2WASM_GUI QT2WASM_QPA_PLATFORM="qt2wasmgui" QT2WASM_GUI_BINDINGS_H="gui.h")
# This UI's own sources share files with Ladybird's headers, which use Qt's keywords (emit, signals) as names.
set_source_files_properties(BrowserWindow.cpp Dialog.cpp Keyring.cpp PageMenu.cpp PasswordBar.cpp Passwords.cpp PopupMenu.cpp KeyMap.cpp MoreMenu.cpp Network.cpp Omnibox.cpp PageFrame.cpp Pages.cpp PdfView.cpp Profile.cpp Sessions.cpp SessionsPage.cpp Sync.cpp SyncDoc.cpp SyncKeys.cpp SyncPages.cpp Vault.cpp WebView.cpp main.cpp PROPERTIES COMPILE_DEFINITIONS QT_NO_KEYWORDS)
# Qt's headers (QJsonValue's bit fields) trip Ladybird's -Wpadded-bitfield in the sources that include them.
set_source_files_properties(BrowserWindow.cpp Dialog.cpp Keyring.cpp PageMenu.cpp PasswordBar.cpp Passwords.cpp PopupMenu.cpp KeyMap.cpp MoreMenu.cpp Omnibox.cpp PageFrame.cpp Pages.cpp PdfView.cpp Profile.cpp Sessions.cpp SessionsPage.cpp Sync.cpp SyncDoc.cpp SyncKeys.cpp SyncPages.cpp Vault.cpp main.cpp
    PROPERTIES COMPILE_OPTIONS "-Wno-padded-bitfield")
# Qt's and qt2wasm's own sources are not written to Ladybird's warning flags.
set_source_files_properties(qt_wasi_shims.c ${moc_outputs} "${gen}/bindings/gui.c" "${qt2wasm_data}/runtime/runtime.cpp"
    "${qt2wasm_data}/runtime/wasieventdispatcher.cpp" "${qt2wasm_data}/gui/qt2wasmgui.cpp"
    PROPERTIES COMPILE_OPTIONS "-w;-Wno-error")
target_compile_options(webby-ui PRIVATE $<$<COMPILE_LANGUAGE:CXX>:-Wno-error=deprecated-declarations>)

# Qt's static archives, in the order its .prl files give, with the resource initialisers its object libraries keep.
# Qt's bundled FreeType, HarfBuzz and libpng are left out: the engine's own (newer, same ABI) serve both. Its zlib
# stays, as its symbols carry a z_ prefix.
target_link_libraries(webby-ui PRIVATE
    "${gen}/bindings/gui_component_type.o" "${gen}/pty/pty_guest_component_type.o"
    "${qt}/lib/objects-Release/Gui_resources_1/.qt/rcc/qrc_qpdf_init.cpp.obj"
    "${qt}/lib/objects-Release/Gui_resources_2/.qt/rcc/qrc_gui_shaders_init.cpp.obj"
    "${qt}/lib/libQt6Gui.a" "${qt}/lib/libQt6Core.a" "${qt}/lib/libQt6BundledPcre2.a" "${qt}/lib/libQt6BundledZLIB.a"
    webby-webgl LibWeb LibCompositing LibGfx LibImageDecoders LibMedia LibFileSystem LibURL skia requestserverservice LibRequests LibCrypto
    OpenSSL::Crypto)
# A reactor: the host calls the exports; there is no main().
target_link_options(webby-ui PRIVATE -mexec-model=reactor)

add_dependencies(webby-ui webby-pdf)
add_custom_command(TARGET webby-ui POST_BUILD
    COMMAND "${WASM_TOOLS}" component new "$<TARGET_FILE:webby-ui>" --adapt "wasi_snapshot_preview1=${adapter}"
        -o "${CMAKE_BINARY_DIR}/bin/webby-ui-app.wasm"
    COMMAND "${WAC}" plug "${CMAKE_BINARY_DIR}/bin/webby-ui-app.wasm" --plug "${pdf_component}" -o "${CMAKE_BINARY_DIR}/bin/webby.wasm"
    COMMENT "Making the latha:gui component bin/webby.wasm (the UI and engine, with webby-pdf.wasm plugged in)" VERBATIM)

# The engine as its own component: WebView.cpp and the Compositor's Skia player behind webby:engine's views
# (wit/engine/engine.wit, engine/EngineExports.cpp). No Qt. shell/ builds the UI that imports it.
set(engine_wit "${CMAKE_CURRENT_SOURCE_DIR}/wit/engine/engine.wit")
add_custom_command(OUTPUT "${gen}/engine/engine.c" "${gen}/engine/engine.h" "${gen}/engine/engine_component_type.o"
    COMMAND "${WIT_BINDGEN}" c "${CMAKE_CURRENT_SOURCE_DIR}/wit/engine" --world engine --out-dir "${gen}/engine"
    DEPENDS "${engine_wit}" VERBATIM)
add_executable(webby-core
    "${WEBBY_NATIVE_DIR}/Authenticator.cpp"
    Network.cpp
    Storage.cpp
    WebView.cpp
    Resources.c
    engine/EngineExports.cpp
    "${gen}/engine/engine.c"
    ${compositor_dir}/Canvas2DCommandPlayer.cpp
    ${compositor_dir}/ColorSpaceSkia.cpp
    ${compositor_dir}/DisplayListPlayer.cpp
    ${compositor_dir}/DisplayListPlayerSkia.cpp
    ${compositor_dir}/DisplayListRasterCache.cpp
    ${compositor_dir}/FontSkia.cpp
    ${compositor_dir}/PainterSkia.cpp
    ${compositor_dir}/PaintingSurface.cpp
    ${compositor_dir}/RasterizeDisplayList.cpp
    ${compositor_dir}/ScrollbarController.cpp
    ${compositor_dir}/SkiaBackendContext.cpp
    ${compositor_dir}/SkiaUtils.cpp
    ${compositor_dir}/VideoFrameSkia.cpp)
set_target_properties(webby-core PROPERTIES SUFFIX ".core.wasm" RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
target_include_directories(webby-core PRIVATE ${LADYBIRD_SOURCE_DIR}/Services ${CMAKE_BINARY_DIR}/Services
    "${CMAKE_CURRENT_SOURCE_DIR}" "${gen}/engine" "${WEBBY_NATIVE_DIR}")
set_source_files_properties("${gen}/engine/engine.c" PROPERTIES COMPILE_OPTIONS "-w;-Wno-error")
target_link_libraries(webby-core PRIVATE "${gen}/engine/engine_component_type.o"
    webby-webgl LibWeb LibCompositing LibGfx LibImageDecoders LibMedia LibFileSystem LibURL skia requestserverservice LibRequests LibCrypto)
target_link_options(webby-core PRIVATE -mexec-model=reactor)
add_custom_command(TARGET webby-core POST_BUILD
    COMMAND "${WASM_TOOLS}" component new "$<TARGET_FILE:webby-core>" --adapt "wasi_snapshot_preview1=${adapter}"
        -o "${CMAKE_BINARY_DIR}/bin/webby-core.wasm"
    COMMENT "Making the engine component bin/webby-core.wasm" VERBATIM)

# KeyCodes.h is Ladybird's key code list copied for the UI component (which has no Ladybird tree): it has to match.
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/KeyCodes.h" _ours)
file(READ "${LADYBIRD_SOURCE_DIR}/Libraries/LibWebCommon/UIEvents/KeyCode.h" _theirs)
string(REGEX MATCH "#define ENUMERATE_KEY_CODES[^\n]*\n([^\n]*\\\\\n)*[^\n]*" _block "${_ours}")
string(FIND "${_theirs}" "${_block}" _at)
if (NOT _block OR _at EQUAL -1)
    message(FATAL_ERROR "wasm/ui/KeyCodes.h no longer matches Ladybird's LibWebCommon/UIEvents/KeyCode.h: copy its ENUMERATE_KEY_CODES again")
endif()
