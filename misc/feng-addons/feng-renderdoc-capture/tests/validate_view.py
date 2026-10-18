"""Validate the actual RenderDoc widgets after its --ui-python startup script."""


def validate_view(context, output_path):
    import json
    import math
    from pathlib import Path
    import time
    import traceback

    from PySide2 import QtCore, QtGui, QtWidgets

    deadline = time.monotonic() + 45
    timer = QtCore.QTimer(context.GetEventBrowser().Widget())
    context._feng_view_validation_timer = timer

    def check():
        result = {}
        try:
            if not context.IsCaptureLoaded():
                assert time.monotonic() < deadline, "Capture never loaded"
                return
            view = context._feng_capture_view
            result["loaded"] = True
            result["api"] = str(context.APIProps().pipelineType)
            result["fatal_error"] = str(context.GetFatalError())
            assert "Success" in result["fatal_error"], result["fatal_error"]
            result["timing_block_reason"] = view.block_reason()
            result["clock_enabled"] = view.time_button.isEnabled()
            if result["timing_block_reason"]:
                assert not result["clock_enabled"] and not view.notice.isHidden()
                # Retry must retain the working replay instead of fetching counters.
                view.request_timing()
                assert "Success" in str(context.GetFatalError())
                context.ShowPerformanceCounterViewer()
                counters = context.GetPerformanceCounterViewer().Widget()
                capture_button = counters.findChild(QtWidgets.QAbstractButton, "captureCounters")
                assert capture_button is not None
                clicks = []
                capture_button.clicked.connect(lambda: clicks.append(True))
                for event_type, buttons in (
                    (QtCore.QEvent.MouseButtonPress, QtCore.Qt.LeftButton),
                    (QtCore.QEvent.MouseButtonRelease, QtCore.Qt.NoButton),
                ):
                    event = QtGui.QMouseEvent(event_type, QtCore.QPointF(1, 1),
                                             QtCore.Qt.LeftButton, buttons, QtCore.Qt.NoModifier)
                    QtWidgets.QApplication.sendEvent(capture_button, event)
                assert not clicks, "Unsafe counter request was not intercepted"
                result["counter_request_blocked"] = True
            else:
                events = view.widget.findChild(QtWidgets.QTreeView, "events")
                model = events.model()
                columns = [column for column in range(model.columnCount())
                           if "Duration" in str(model.headerData(column, QtCore.Qt.Horizontal))]
                assert columns, "GPU duration column is missing"
                column = columns[0]
                assert not events.isColumnHidden(column), "GPU durations were not enabled"
                result["gpu_duration_column"] = str(model.headerData(column, QtCore.Qt.Horizontal))
                values = []
                pending = [QtCore.QModelIndex()]
                while pending and len(values) < 10000:
                    parent = pending.pop()
                    for row in range(model.rowCount(parent)):
                        index = model.index(row, 0, parent)
                        pending.append(index)
                        values.append(str(model.data(model.index(row, column, parent))))
                result["duration_cells"] = values
                durations = []
                for value in values:
                    try:
                        duration = float(value.replace(",", ""))
                        if math.isfinite(duration) and duration > 0:
                            durations.append(duration)
                    except ValueError:
                        pass
                if not durations:
                    assert time.monotonic() < deadline, "No GPU timestamp results arrived"
                    return
                result["positive_gpu_duration_count"] = len(durations)
            result["status"] = "PASS"
        except Exception:
            result["status"] = "FAIL"
            result["exception"] = traceback.format_exc()
        timer.stop()
        Path(output_path).write_text(json.dumps(result, indent=2), encoding="utf-8")

    timer.timeout.connect(check)
    timer.start(250)
