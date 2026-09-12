"""Keep idle configured passes visible in captures opened by the editor."""

# qrenderdoc --ui-python supplies pyrenderdoc as the current UI context.
# Keep the user's action filter, including when a pass has no work this frame.
pyrenderdoc.GetEventBrowser().SetEmptyRegionsVisible(True)
