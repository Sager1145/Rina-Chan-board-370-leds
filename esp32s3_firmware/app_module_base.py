# ---------------------------------------------------------------------------
# app_module_base.py
#
# Forwarding base class for feature modules.  Modules own feature code but the
# mutable runtime state remains in LinaBoardApp, so module reads/writes act on
# the main app facade instead of creating separate per-module state shadows.
# ---------------------------------------------------------------------------


# Class: Defines AppModule as the state and behavior container for App Module.
class AppModule:
    # Variable: __slots__ stores the collection of values used later in this module.
    __slots__ = ("app",)

    # Function: Defines __init__(self, app) to handle init behavior.
    def __init__(self, app):
        # Expression: Calls object.__setattr__() for its side effects.
        object.__setattr__(self, "app", app)

    # Function: Defines __getattr__(self, name) to handle getattr behavior.
    def __getattr__(self, name):
        # Return: Sends the result returned by getattr() back to the caller.
        return getattr(self.app, name)

    # Function: Defines __setattr__(self, name, value) to handle setattr behavior.
    def __setattr__(self, name, value):
        # Logic: Branches when name == "app" so the correct firmware path runs.
        if name == "app":
            # Expression: Calls object.__setattr__() for its side effects.
            object.__setattr__(self, name, value)
        # Logic: Runs this fallback branch when the earlier condition did not match.
        else:
            # Expression: Calls setattr() for its side effects.
            setattr(self.app, name, value)
