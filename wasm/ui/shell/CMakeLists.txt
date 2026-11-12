# webby's Qt UI as a small latha:gui component that imports the engine component (../wit/ui/ui.wit): BrowserWindow,
# KeyMap and main.cpp from .., and WebViewRemote.cpp in place of WebView.cpp. No Ladybird tree, no engine build:
# only Qt for WASI and qt2wasm (WEBBY_QT_ENV, the wasm/ pixi env or a micromamba env with qt2wasm, qt6-wasi,
# wit-bindgen, wasm-tools, wasi-preview1-adapter). build.sh configures it with Qt's toolchain and composes the result
# with webby-core.wasm (wac plug).
#
# Output: webby-ui-shell.core.wasm (the module) and webby-ui-shell.wasm (the component, imports webby:engine/views).

cmake_minimum_required(VERSION 3.25)
project(webby-ui-shell C CXX)
set(CMAKE_CXX_STANDARD 23)

set(ui "${CMAKE_CURRENT_SOURCE_DIR}/..")
if (NOT WEBBY_QT_ENV)
    message(FATAL_ERROR "set WEBBY_QT_ENV")
endif()
set(qt "${WEBBY_QT_ENV}/opt/qt6-wasi/wasi")
set(qt_version 6.8.3)
file(GLOB qt2wasm_data LIST_DIRECTORIES true "${WEBBY_QT_ENV}/lib/python3*/site-packages/qt2wasm/_data")
set(moc "${WEBBY_QT_ENV}/opt/qt6-wasi/host/libexec/moc")
find_program(WIT_BINDGEN wit-bindgen HINTS "${WEBBY_QT_ENV}/bin" REQUIRED)
find_program(WASM_TOOLS wasm-tools HINTS "${WEBBY_QT_ENV}/bin" REQUIRED)
set(adapter "${WEBBY_QT_ENV}/share/wasi-preview1-adapter/wasi_snapshot_preview1.reactor.wasm")
set(gen "${CMAKE_CURRENT_BINARY_DIR}/gen")

# moc, for BrowserWindow and qt2wasm's runtime and GUI platform plugin.
set(moc_outputs)
foreach (header "${ui}/BrowserWindow.h" "${qt2wasm_data}/runtime/wasieventdispatcher.h" "${qt2wasm_data}/gui/qt2wasmgui.h")
    get_filename_component(name "${header}" NAME_WE)
    add_custom_command(OUTPUT "${gen}/moc_${name}.cpp" COMMAND "${moc}" "${header}" -o "${gen}/moc_${name}.cpp"
        DEPENDS "${header}" VERBATIM)
    list(APPEND moc_outputs "${gen}/moc_${name}.cpp")
endforeach()

# The world `gui` of webby:ui: latha:gui's app plus webby:engine's views. Its deps/ are copied in.
set(ui_wit "${ui}/wit/ui/ui.wit" "${ui}/wit/engine/engine.wit" "${qt2wasm_data}/gui/wit/gui.wit" "${ui}/../pdf/wit/pdf.wit")
add_custom_command(OUTPUT "${gen}/bindings/gui.c" "${gen}/bindings/gui.h" "${gen}/bindings/gui_component_type.o"
    COMMAND ${CMAKE_COMMAND} -E rm -rf "${gen}/wit"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${gen}/wit/deps/engine" "${gen}/wit/deps/gui" "${gen}/wit/deps/pdf"
    COMMAND ${CMAKE_COMMAND} -E copy "${ui}/wit/ui/ui.wit" "${gen}/wit/"
    COMMAND ${CMAKE_COMMAND} -E copy "${ui}/wit/engine/engine.wit" "${gen}/wit/deps/engine/"
    COMMAND ${CMAKE_COMMAND} -E copy "${qt2wasm_data}/gui/wit/gui.wit" "${gen}/wit/deps/gui/"
    COMMAND ${CMAKE_COMMAND} -E copy "${ui}/../pdf/wit/pdf.wit" "${gen}/wit/deps/pdf/"
    COMMAND "${WIT_BINDGEN}" c "${gen}/wit" --world gui --out-dir "${gen}/bindings"
    DEPENDS ${ui_wit} VERBATIM)

add_executable(webby-ui-shell
    ${ui}/BrowserWindow.cpp
    ${ui}/Dialog.cpp
    ${ui}/PageMenu.cpp
    ${ui}/PopupMenu.cpp
    ${ui}/KeyMap.cpp
    ${ui}/MoreMenu.cpp
    ${ui}/Omnibox.cpp
    ${ui}/PageFrame.cpp
    ${ui}/Pages.cpp
    ${ui}/PdfView.cpp
    ${ui}/Profile.cpp
    ${ui}/Resources.c
    ${ui}/main.cpp
    WebViewRemote.cpp
    PasswordsStub.cpp
    ${moc_outputs}
    "${gen}/bindings/gui.c"
    "${qt2wasm_data}/runtime/runtime.cpp"
    "${qt2wasm_data}/runtime/wasieventdispatcher.cpp"
    "${qt2wasm_data}/gui/qt2wasmgui.cpp"
    "${WASI_QT_COMPAT_C}")
set_target_properties(webby-ui-shell PROPERTIES SUFFIX ".core.wasm")
# The chrome's fonts only (no engine theme here).
set_source_files_properties(${ui}/Resources.c PROPERTIES COMPILE_OPTIONS "-std=gnu23;--embed-dir=${ui}/fonts"
    COMPILE_DEFINITIONS WEBBY_RESOURCES_NO_THEME OBJECT_DEPENDS "${ui}/fonts/LiberationSans-Regular.ttf")
target_include_directories(webby-ui-shell PRIVATE
    "${ui}" "${gen}/bindings"
    "${qt2wasm_data}/include" "${qt2wasm_data}/runtime" "${qt2wasm_data}/gui"
    "${qt}/include" "${qt}/include/QtCore" "${qt}/include/QtGui" "${qt}/mkspecs/wasi-clang"
    "${qt}/include/QtCore/${qt_version}" "${qt}/include/QtCore/${qt_version}/QtCore"
    "${qt}/include/QtGui/${qt_version}" "${qt}/include/QtGui/${qt_version}/QtGui")
target_compile_definitions(webby-ui-shell PRIVATE QT_CORE_LIB QT_GUI_LIB QT_NO_DEBUG QT_STATIC QT_STATICPLUGIN
    QT2WASM_GUI QT2WASM_QPA_PLATFORM="qt2wasmgui" QT2WASM_GUI_BINDINGS_H="gui.h")
set_source_files_properties(${moc_outputs} "${gen}/bindings/gui.c" "${qt2wasm_data}/runtime/runtime.cpp"
    "${qt2wasm_data}/runtime/wasieventdispatcher.cpp" "${qt2wasm_data}/gui/qt2wasmgui.cpp" "${WASI_QT_COMPAT_C}"
    PROPERTIES COMPILE_OPTIONS "-w")

# Qt's static archives in its .prl order, with the resource initialisers its object libraries keep. Here Qt's own
# FreeType, HarfBuzz and libpng serve (the engine's are in the other component).
target_link_libraries(webby-ui-shell PRIVATE
    "${gen}/bindings/gui_component_type.o"
    "${qt}/lib/objects-Release/Gui_resources_1/.qt/rcc/qrc_qpdf_init.cpp.obj"
    "${qt}/lib/objects-Release/Gui_resources_2/.qt/rcc/qrc_gui_shaders_init.cpp.obj"
    "${qt}/lib/libQt6Gui.a" "${qt}/lib/libQt6BundledHarfbuzz.a" "${qt}/lib/libQt6BundledFreetype.a"
    "${qt}/lib/libQt6BundledLibpng.a" "${qt}/lib/libQt6Core.a" "${qt}/lib/libQt6BundledPcre2.a"
    "${qt}/lib/libQt6BundledZLIB.a" m)
target_link_options(webby-ui-shell PRIVATE -mexec-model=reactor -Wl,--gc-sections --no-wasm-opt)

add_custom_command(TARGET webby-ui-shell POST_BUILD
    COMMAND "${WASM_TOOLS}" component new "$<TARGET_FILE:webby-ui-shell>" --adapt "wasi_snapshot_preview1=${adapter}"
        -o "${CMAKE_CURRENT_BINARY_DIR}/webby-ui-shell.wasm"
    COMMENT "Making the UI component webby-ui-shell.wasm" VERBATIM)
