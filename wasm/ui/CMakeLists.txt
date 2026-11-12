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
file(GLOB gui_wit "${qt2wasm_data}/gui/wit/*.wit")
add_custom_command(OUTPUT "${gen}/bindings/gui.c" "${gen}/bindings/gui.h" "${gen}/bindings/gui_component_type.o"
    COMMAND "${WIT_BINDGEN}" c "${qt2wasm_data}/gui/wit" --world gui --out-dir "${gen}/bindings"
    DEPENDS ${gui_wit} VERBATIM)

set(compositor_dir ${LADYBIRD_SOURCE_DIR}/Services/Compositor)
add_executable(webby-ui
    BrowserWindow.cpp
    PageMenu.cpp
    PopupMenu.cpp
    KeyMap.cpp
    Network.cpp
    Omnibox.cpp
    PageFrame.cpp
    Pages.cpp
    Profile.cpp
    Resources.c
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
    "${CMAKE_CURRENT_SOURCE_DIR}" "${gen}/bindings"
    "${qt2wasm_data}/include" "${qt2wasm_data}/runtime" "${qt2wasm_data}/gui"
    "${qt}/include" "${qt}/include/QtCore" "${qt}/include/QtGui" "${qt}/mkspecs/wasi-clang"
    "${qt}/include/QtCore/${qt_version}" "${qt}/include/QtCore/${qt_version}/QtCore"
    "${qt}/include/QtGui/${qt_version}" "${qt}/include/QtGui/${qt_version}/QtGui")
target_compile_definitions(webby-ui PRIVATE QT_CORE_LIB QT_GUI_LIB QT_NO_DEBUG QT_STATIC QT_STATICPLUGIN
    QT2WASM_GUI QT2WASM_QPA_PLATFORM="qt2wasmgui" QT2WASM_GUI_BINDINGS_H="gui.h")
# This UI's own sources share files with Ladybird's headers, which use Qt's keywords (emit, signals) as names.
set_source_files_properties(BrowserWindow.cpp PageMenu.cpp PopupMenu.cpp KeyMap.cpp Network.cpp Omnibox.cpp PageFrame.cpp Pages.cpp Profile.cpp WebView.cpp main.cpp PROPERTIES COMPILE_DEFINITIONS QT_NO_KEYWORDS)
# Qt's headers (QJsonValue's bit fields) trip Ladybird's -Wpadded-bitfield in the sources that include them.
set_source_files_properties(BrowserWindow.cpp PageMenu.cpp PopupMenu.cpp KeyMap.cpp Omnibox.cpp PageFrame.cpp Pages.cpp Profile.cpp main.cpp
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
    "${gen}/bindings/gui_component_type.o"
    "${qt}/lib/objects-Release/Gui_resources_1/.qt/rcc/qrc_qpdf_init.cpp.obj"
    "${qt}/lib/objects-Release/Gui_resources_2/.qt/rcc/qrc_gui_shaders_init.cpp.obj"
    "${qt}/lib/libQt6Gui.a" "${qt}/lib/libQt6Core.a" "${qt}/lib/libQt6BundledPcre2.a" "${qt}/lib/libQt6BundledZLIB.a"
    LibWeb LibCompositing LibGfx LibImageDecoders LibMedia LibFileSystem LibURL skia requestserverservice LibRequests)
# A reactor: the host calls the exports; there is no main().
target_link_options(webby-ui PRIVATE -mexec-model=reactor)

add_custom_command(TARGET webby-ui POST_BUILD
    COMMAND "${WASM_TOOLS}" component new "$<TARGET_FILE:webby-ui>" --adapt "wasi_snapshot_preview1=${adapter}"
        -o "${CMAKE_BINARY_DIR}/bin/webby.wasm"
    COMMENT "Making the latha:gui component bin/webby.wasm" VERBATIM)

# The engine as its own component: WebView.cpp and the Compositor's Skia player behind webby:engine's views
# (wit/engine/engine.wit, engine/EngineExports.cpp). No Qt. shell/ builds the UI that imports it.
set(engine_wit "${CMAKE_CURRENT_SOURCE_DIR}/wit/engine/engine.wit")
add_custom_command(OUTPUT "${gen}/engine/engine.c" "${gen}/engine/engine.h" "${gen}/engine/engine_component_type.o"
    COMMAND "${WIT_BINDGEN}" c "${CMAKE_CURRENT_SOURCE_DIR}/wit/engine" --world engine --out-dir "${gen}/engine"
    DEPENDS "${engine_wit}" VERBATIM)
add_executable(webby-core
    Network.cpp
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
    "${CMAKE_CURRENT_SOURCE_DIR}" "${gen}/engine")
set_source_files_properties("${gen}/engine/engine.c" PROPERTIES COMPILE_OPTIONS "-w;-Wno-error")
target_link_libraries(webby-core PRIVATE "${gen}/engine/engine_component_type.o"
    LibWeb LibCompositing LibGfx LibImageDecoders LibMedia LibFileSystem LibURL skia requestserverservice LibRequests)
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
