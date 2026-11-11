# webby's Qt UI as one latha:gui WebAssembly component: QtGui chrome (BrowserWindow) and Ladybird's LibWeb (WebView)
# in one module. Built inside Ladybird's WASI build (ENABLE_GUI_TARGETS=ON) when WEBBY_UI_DIR names this directory:
# Utilities/CMakeLists.txt (wasm/patches/0011) adds it; it shares webby-render's Compositor sources.
#
# Qt for WASI and the qt2wasm GUI pieces come from the wasm/ pixi env (qt2wasm, qt6-wasi, wit-bindgen, wasm-tools,
# wasi-preview1-adapter): WEBBY_QT_ENV, which defaults to the env that holds $WASI_SDK_PREFIX. This is what
# `qt2wasm build --gui` does (Qt2Wasm.cmake, qt2wasm/build.py), spelled out so that it can live in Ladybird's build.
#
# Output: bin/webby-ui.core.wasm (the reactor module, after the build's spill-pointers pass) and bin/webby.wasm (the
# component a latha:gui host runs).

cmake_minimum_required(VERSION 3.25)

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
    KeyMap.cpp
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
set_source_files_properties(BrowserWindow.cpp KeyMap.cpp WebView.cpp main.cpp PROPERTIES COMPILE_DEFINITIONS QT_NO_KEYWORDS)
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
    LibWeb LibCompositing LibGfx LibMedia LibFileSystem LibURL skia)
# A reactor: the host calls the exports; there is no main().
target_link_options(webby-ui PRIVATE -mexec-model=reactor)

add_custom_command(TARGET webby-ui POST_BUILD
    COMMAND "${WASM_TOOLS}" component new "$<TARGET_FILE:webby-ui>" --adapt "wasi_snapshot_preview1=${adapter}"
        -o "${CMAKE_BINARY_DIR}/bin/webby.wasm"
    COMMENT "Making the latha:gui component bin/webby.wasm" VERBATIM)
