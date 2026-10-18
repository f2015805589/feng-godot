"""Configure captured passes and GPU timings in the current RenderDoc UI."""

import sys


def developer_mode_enabled():
    """Read the setting on the replay machine without changing Windows policy."""
    if sys.platform != "win32":
        return None
    import winreg

    try:
        with winreg.OpenKey(
            winreg.HKEY_LOCAL_MACHINE,
            r"SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock",
            0,
            winreg.KEY_READ | winreg.KEY_WOW64_64KEY,
        ) as key:
            value, _ = winreg.QueryValueEx(key, "AllowDevelopmentWithoutDevLicense")
            return value == 1
    except FileNotFoundError:
        return False
    except OSError:
        return None


def timing_block_reason(is_d3d12, remote_replay=False):
    # A local registry setting cannot describe a remote replay machine.
    if not is_d3d12 or sys.platform != "win32" or remote_replay:
        return ""
    if developer_mode_enabled() is True:
        return ""
    return (
        "D3D12 GPU timing requires Windows Developer Mode. Enable it in Windows Settings, "
        "then click Retry GPU timing. Capture inspection remains available."
    )


def install_capture_view(context):
    import qrenderdoc
    import renderdoc
    from PySide2 import QtCore, QtGui, QtWidgets

    class CaptureView(qrenderdoc.CaptureViewer):
        def __init__(self):
            super().__init__()
            self.browser = context.GetEventBrowser()
            self.widget = self.browser.Widget()
            self.time_button = self.widget.findChild(QtWidgets.QAbstractButton, "timeActions")
            self.notice = QtWidgets.QWidget(self.widget)
            self.notice.setObjectName("fengGpuTimingNotice")
            layout = QtWidgets.QHBoxLayout(self.notice)
            layout.setContentsMargins(4, 4, 4, 4)
            self.message = QtWidgets.QLabel()
            self.message.setWordWrap(True)
            layout.addWidget(self.message, 1)
            self.settings_button = QtWidgets.QPushButton("Windows Settings")
            self.settings_button.clicked.connect(self.open_settings)
            layout.addWidget(self.settings_button)
            retry = QtWidgets.QPushButton("Retry GPU timing")
            retry.setObjectName("fengRetryGpuTiming")
            retry.clicked.connect(self.request_timing)
            layout.addWidget(retry)
            self.widget.layout().insertWidget(0, self.notice)
            self.notice.hide()
            self.guard = TimingGuard(self.widget, self)
            QtWidgets.QApplication.instance().installEventFilter(self.guard)
            self.configure_timer = QtCore.QTimer(self.widget)
            self.configure_timer.setSingleShot(True)
            self.configure_timer.timeout.connect(self.configure_capture)
            context.AddCaptureViewer(self)
            if context.IsCaptureLoaded():
                self.OnCaptureLoaded()

        def block_reason(self):
            properties = context.APIProps()
            return timing_block_reason(
                properties.pipelineType == renderdoc.GraphicsAPI.D3D12,
                properties.remoteReplay,
            )

        def show_notice(self, reason):
            self.message.setText(reason)
            self.settings_button.setVisible(sys.platform == "win32" and not context.APIProps().remoteReplay)
            self.notice.setVisible(bool(reason))
            if self.time_button is not None:
                self.time_button.setEnabled(context.IsCaptureLoaded() and not reason)
                self.time_button.setToolTip(reason or "Measure GPU durations for the captured actions")

        def request_timing(self):
            if not context.IsCaptureLoaded():
                return
            reason = self.block_reason()
            if self.time_button is None:
                reason = "Use the Event Browser clock button to measure GPU durations in this RenderDoc version."
            self.show_notice(reason)
            if not reason:
                # Use RenderDoc's own asynchronous replay and duration aggregation.
                # Never substitute CPU submission/capture time for a GPU duration.
                self.time_button.click()

        def open_settings(self):
            QtGui.QDesktopServices.openUrl(QtCore.QUrl("ms-settings:developers"))

        def OnCaptureLoaded(self):
            # Native viewers also reset their controls during this notification.
            self.configure_timer.start(0)

        def configure_capture(self):
            if not context.IsCaptureLoaded():
                return
            self.browser.SetEmptyRegionsVisible(True)
            if context.APIProps().remoteReplay:
                return  # Keep remote timing under the native clock's manual control.
            self.request_timing()

        def OnCaptureClosed(self):
            self.configure_timer.stop()
            self.notice.hide()

        def OnSelectedEventChanged(self, event_id):
            pass

        def OnEventChanged(self, event_id):
            pass

    class TimingGuard(QtCore.QObject):
        def __init__(self, parent, view):
            super().__init__(parent)
            self.view = view

        def eventFilter(self, watched, event):
            # Cover the native clock and counter window, including windows opened
            # later. Recheck Windows policy before each interactive request.
            if watched.objectName() not in ("timeActions", "captureCounters"):
                return False
            if event.type() not in (
                QtCore.QEvent.MouseButtonPress,
                QtCore.QEvent.MouseButtonDblClick,
                QtCore.QEvent.KeyPress,
                QtCore.QEvent.Shortcut,
            ):
                return False
            if event.type() == QtCore.QEvent.KeyPress and event.key() not in (
                QtCore.Qt.Key_Space, QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter
            ):
                return False
            if not context.IsCaptureLoaded():
                return False
            reason = self.view.block_reason()
            if not reason:
                return False
            self.view.show_notice(reason)
            watched.setToolTip(reason)
            return True

    # Retain the viewer and its callbacks for the lifetime of this UI context.
    context._feng_capture_view = CaptureView()


if "pyrenderdoc" in globals():
    # --ui-python runs in the Python shell. All Qt work belongs on the UI thread.
    pyrenderdoc.Extensions().GetMiniQtHelper().InvokeOntoUIThread(
        lambda: install_capture_view(pyrenderdoc)
    )
