# Link into app before ZMK's combo/hold-tap listeners, rather than a separate library.
target_sources_ifdef(CONFIG_P31N_TELEMETRY app PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}/telemetry.c)
target_include_directories(app PRIVATE ${CMAKE_CURRENT_LIST_DIR})
