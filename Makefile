PROJECT = jorel

DEPS = sh erlconf vsn color bucs getopt erlydtl tempfile

DOC_DEPS = edown

LOCAL_DEPS = ssl inets

dep_sh = git https://github.com/gleber/sh.git master
dep_erlconf = git https://github.com/emedia-project/erlconf.git master
dep_vsn = git https://github.com/emedia-project/vsn.git master
dep_color = git https://github.com/julianduque/erlang-color.git master
dep_bucs = git https://github.com/botsunit/bucs.git master
dep_getopt = git https://github.com/jcomellas/getopt.git master
dep_erlydtl = git https://github.com/erlydtl/erlydtl.git master
dep_tempfile = git https://github.com/botsunit/tempfile.git master
dep_edown = git https://github.com/uwiger/edown.git master

all:: escript
tests:: escript

include erlang.mk

EDOC_OPTS = {doclet, edown_doclet} \
						, {app_default, "http://www.erlang.org/doc/man"} \
						, {source_path, ["src"]} \
						, {overview, "overview.edoc"} \
						, {stylesheet, ""} \
						, {image, ""} \
						, {top_level_readme, {"./README.md", "https://github.com/emedia-project/${PROJECT}"}}

EUNIT_OPTS = verbose, {report, {eunit_surefire, [{dir, "test"}]}}

ESCRIPT_SYS_CONFIG = "config/jorel.config"

VERSION = $(shell ./tag)
release: escript
ifeq ($(VERSION),ERROR)
	@echo "**> Can't find version!"
else
	@echo "==> Release version $(VERSION)"
	git clone git@github.com:emedia-project/$(PROJECT).wiki.git
	cp $(PROJECT) $(PROJECT).wiki/$(PROJECT)
	cd $(PROJECT).wiki; git commit -am "New release $(VERSION)"; git push origin master
	rm -rf $(PROJECT).wiki
endif

dev: deps app
	$(verbose) erl -pa ebin include deps/*/ebin deps/*/include

distclean::
	$(verbose) rm -rf .tests
	$(verbose) rm -f test/TEST-*.xml

