EMACS ?= emacs
BATCH := $(EMACS) -Q --batch

SRC := vulpea-dblock-registry.el vulpea-dblock-render.el \
       vulpea-dblock-scheduler.el vulpea-dblock.el

TESTS := tests/test-registry.el tests/test-render.el \
         tests/test-scheduler.el tests/test-integration.el

.PHONY: all compile test clean

all: compile test

# vulpea and its dependencies are located through package.el
# (package-initialize picks up the user's package dir).
compile:
	$(BATCH) --eval '(progn (require (quote package)) (package-initialize))' \
	  -L . --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SRC)

test:
	$(BATCH) -L . -L tests -l tests/test-helper.el \
	  $(addprefix -l ,$(TESTS)) \
	  -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc tests/*.elc
