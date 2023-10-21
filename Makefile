# Set this to specify target application.
# It defaults current dir name.
prog ?= $(notdir $(shell bash -c 'sed "s%^\(.*\)/%\1%g" <<< $(dir $(realpath $(firstword $(MAKEFILE_LIST))))'))

# Set run args
run-args ?=

# Set this to any non-empty string to enable unoptimized
# build w/ debugging features.
debug ?=

# Get crate version by parsing the line that starts with version.
CRATE_VERSION ?= $(shell grep ^version Cargo.toml | awk '{print $$3}')
GIT_TAG ?= $(shell git describe --tags)

# Get crate type
CRATE_TYPE ?= $(shell bash -c 'sed "s/\[\(.*\)\]/\1/" <<< '$(shell bash -c 'grep "^\[lib\]" Cargo.toml') 2>/dev/null)

# Set path to cargo executable
CARGO ?= cargo

# Set linker
RUSTFLAGS += -C linker=clang -C link-arg=-fuse-ld=lld
export RUSTFLAGS

# All complication artifacts, including dependencies and intermediates
# will be stored here, for all architectures.  Use a non-default name
# since the (default) 'target' is used/referenced ambiguously in many
# places in the tool-chain (including 'make' itself).
CARGO_TARGET_DIR ?= targets
export CARGO_TARGET_DIR  # 'cargo' is sensitive to this env. var. value.

ifdef debug
  # These affect both $(CARGO_TARGET_DIR) layout and contents
  # Ref: https://doc.rust-lang.org/cargo/guide/build-cache.html
  release :=
  profile :=debug
else
  release :=--release
  profile :=release
endif

.PHONY: all
all: build

bin:
	mkdir -p $@

$(CARGO_TARGET_DIR):
	mkdir -p $@

.PHONY: build
build: bin $(CARGO_TARGET_DIR)
	$(CARGO) build $(release)
	cp $(CARGO_TARGET_DIR)/$(profile)/$(prog) bin/$(prog)$(if $(debug),.debug,)

.PHONY: examples
examples: bin $(CARGO_TARGET_DIR)
	cargo build --examples $(release)

.PHONY: crate-publish
crate-publish:
	@if [ "v$(CRATE_VERSION)" != "$(GIT_TAG)" ]; then\
		echo "Git tag is not equivalent to the version set in Cargo.toml. Please checkout the correct tag";\
		exit 1;\
	fi
	@echo "It is expected that you have already done 'cargo login' before running this command. If not command may fail later"
	$(CARGO) publish --dry-run
	$(CARGO) publish

.PHONY: clean
clean:
	rm -rf bin docs
	if [ "$(CARGO_TARGET_DIR)" = "targets" ]; then rm -rf targets; fi
	rm -f bindgen/*.o bindgen/*.a

.PHONY: docs
docs: ## build the docs on the host
	mkdir -p $@
	$(CARGO) doc $(release) --no-deps

.PHONY: install
install: docs
	cp -r $(CARGO_TARGET_DIR)/docs/ docs/

.PHONY: uninstall
uninstall:
	rm -f $(PREFIX)/share/man/man1/$(prog)*.1

.PHONY: run
run: bin ./bin/$(prog)
	./bin/$(prog) $(run-args)

.PHONY: test
test: unit integration doc_test

# Used by CI to compile the unit tests but not run them
.PHONY: build_unit
build_unit: $(CARGO_TARGET_DIR)
	$(CARGO) test --no-run

.PHONY: unit
unit: $(CARGO_TARGET_DIR)
	$(CARGO) test

.PHONY: integration
integration: $(CARGO_TARGET_DIR) examples
	# may needs to be run as root
	bats test/

.PHONY: doc_test
doc_test: $(CARGO_TARGET_DIR)
	@if [ "$(CRATE_TYPE)" = "bin" ] || [ "$(CRATE_TYPE)" = "" ]; then
		echo "test for doc was not proceed since crate type is bin, not lib."; \
	else \
		$(CARGO) test --doc \
	fi

.PHONY: validate
validate: $(CARGO_TARGET_DIR)
	$(CARGO) fmt --all
	$(CARGO) clippy -p $(prog)@$(CRATE_VERSION) -- -D warnings

.PHONY: vendor-tarball
vendor-tarball: build install.cargo-vendor-filterer
	$(CARGO) vendor-filterer --format=tar.gz --prefix vendor/ && \
	mv vendor.tar.gz $(prog)-v$(CRATE_VERSION)-vendor.tar.gz && \
	gzip -c bin/$(prog) > $(prog).gz && \
	sha256sum $(prog).gz $(prog)-v$(CRATE_VERSION)-vendor.tar.gz > sha256sum

.PHONY: install.cargo-vendor-filterer
install.cargo-vendor-filterer:
	$(CARGO) install cargo-vendor-filterer

define HELP_MESSAGE
usage: make [subcommand] [prog=your_program_name] [run-args=args] [debug=1]
	subcommands:
		build:		build prog (default)
		clean:		delete binaries and docs
		crate-publish:	cargo publish
		docs:		create docs
		examples:	build examples
		install:	locate outputs to system path
		run:		run program with run-args
		test:		run unit and integration tests
		uninstall:	delete outputs from system path
		validate:	fmt and clippy check
		vendor-tarball:	create vendor/ tarball
		help:		show this message
endef
.PHONY: help
help:
	$(info $(HELP_MESSAGE))
# suppress "Nothing to be done" message
	@:

