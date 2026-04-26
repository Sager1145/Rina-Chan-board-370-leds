# ---------------------------------------------------------------------------
# app_module_base.py
#
# Forwarding base class for feature modules.  Modules own feature code but the
# mutable runtime state remains in LinaBoardApp, so module reads/writes act on
# the main app facade instead of creating separate per-module state shadows.
# ---------------------------------------------------------------------------


class AppModule:
    __slots__ = ("app",)

    def __init__(self, app):
        object.__setattr__(self, "app", app)

    def __getattr__(self, name):
        return getattr(self.app, name)

    def __setattr__(self, name, value):
        if name == "app":
            object.__setattr__(self, name, value)
        else:
            setattr(self.app, name, value)
