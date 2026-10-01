extends SceneTree
func _initialize():
    run.call_deferred()
func run():
    var pid := RenderDocCapture.relaunch_with_renderdoc(OS.get_environment("FENG_RELAUNCH_HELPER"))
    if pid <= 0:
        push_error("REGRESSION: fake renderdoccmd process was not started")
        quit(1)
        return
    for i in 40:
        if not OS.is_process_running(pid):
            break
        await create_timer(0.05).timeout
    var expected := PackedStringArray(["launch", OS.get_executable_path()])
    expected.append_array(OS.get_cmdline_args())
    var user := OS.get_cmdline_user_args()
    if not user.is_empty():
        expected.append("--")
        expected.append_array(user)
    var actual: Variant = JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("FENG_RELAUNCH_ARGUMENTS")))
    print("RELAUNCH expected=", Array(expected), " actual=", actual)
    if actual != Array(expected):
        push_error("REGRESSION: relaunch dropped engine or user command-line arguments")
        quit(1)
        return
    print("PASS RenderDoc relaunch preserves engine and user arguments")
    quit()
