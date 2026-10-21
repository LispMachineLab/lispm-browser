EMACS ?= emacs
# The sources, in lisp/, in the order they require each other.
ELS = $(addprefix lisp/,lispm-browser.el lispm-browser-places.el lispm-browser-hints.el \
      lispm-browser-extensions.el lispm-browser-proxy.el)

.PHONY: all compile test webext webext-test clean

all: compile test

# Warnings are errors: CI compiles with every supported Emacs.  The .elc
# files are removed again, as they would shadow the sources of a checkout
# Emacs loads from.
compile:
	$(EMACS) -Q --batch -L lisp --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile $(ELS); \
	status=$$?; rm -f lisp/*.elc; exit $$status

# Tests stub a few primitives; the code they test runs uncompiled, so the
# native compiler need not build trampolines for them, which takes seconds.
test:
	$(EMACS) -Q --batch --eval '(setq native-comp-enable-subr-trampolines nil)' \
	  -L lisp -l test/lispm-browser-test.el -f ert-run-tests-batch-and-exit

# lispm-browser-extensions's module: Chrome extensions in the pages, on
# macOS, in Swift.  lispm-browser builds it itself the first time an
# extension is added, and again at a start that finds its sources changed.
webext:
	cd native/lispm-browser-webext && swift build -c release --product lispm_browser_webext

# The module's own tests, which need no Emacs.
webext-test:
	cd native/lispm-browser-webext && swift test

clean:
	rm -f lisp/*.elc test/*.elc
