SHELL   := /bin/bash
FLAVOR  ?= x64v4
FLAVORS := $(shell . ./kernel.env && echo $$FLAVORS)
IMAGE   ?= linux-cachyos-deb:$(shell . ./kernel.env && echo $$UBUNTU_SERIES)
PORT    ?= 8000

export FLAVOR

# The stages are strictly ordered and share the objtree, so they must never be
# taken as independent prerequisites and run concurrently.
.NOTPARALLEL:

.PHONY: image preflight fetch config build package repo sign profile profile-report profile-release serve all everything clean distclean

image:      ; @docker build --build-arg LLVM_VERSION=$(shell . ./kernel.env && echo $$LLVM_VERSION) -t $(IMAGE) docker/
preflight:  ; @bash scripts/preflight.sh
fetch:      ; @bash scripts/fetch.sh
config:     ; @bash scripts/incontainer.sh bash scripts/configure.sh
build:      ; @bash scripts/incontainer.sh bash scripts/build.sh
package:    ; @bash scripts/incontainer.sh bash scripts/package.sh
repo:       ; @bash scripts/incontainer.sh bash scripts/mkrepo.sh
sign:       ; @bash scripts/sign-repo.sh
# HOST=<ssh-host|local> SECS=<total> SEG=<per-segment>
profile:    ; @bash scripts/profile.sh $(HOST) $(SECS) $(SEG)
# MIN=<percent> — how much of the profile must still match the kernel
profile-report: ; @bash scripts/profile-report.sh $(MIN)
# Full one-shot on a new release: load -> record -> gate -> upload to CI repo.
# HOST=<ssh-host> SECS=<total>
profile-release: ; @bash scripts/profile-release.sh $(HOST) $(SECS)

# One flavor, end to end.
all:
	@for s in preflight fetch config build package; do $(MAKE) --no-print-directory $$s || exit 1; done

# Every flavor in kernel.env, then the repo index.
everything:
	@for s in preflight fetch; do $(MAKE) --no-print-directory $$s || exit 1; done
	@for f in $(FLAVORS); do \
	    for s in config build package; do \
	        $(MAKE) --no-print-directory FLAVOR=$$f $$s || exit 1; \
	    done; \
	done
	@for s in repo sign; do $(MAKE) --no-print-directory $$s || exit 1; done

serve:
	@echo "apt source for a test machine:"
	@echo "  deb [trusted=yes] http://$$(hostname -I | awk '{print $$1}'):$(PORT)/ ./"
	@cd repo && python3 -m http.server $(PORT) --bind 0.0.0.0

clean:      ; @rm -rf work out repo
distclean: clean
	@rm -rf src
