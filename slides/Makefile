TYPST ?= typst
FONT_PATH ?= theme/_assets/fonts
BUILD_DIR ?= build

DECK := session2.typ
OUT := $(BUILD_DIR)/session2.pdf

THEME_FILES := $(shell find theme -type f)

.PHONY: all clean

all: $(OUT)

$(OUT): $(DECK) $(THEME_FILES)
	mkdir -p $(BUILD_DIR)
	$(TYPST) compile --font-path $(FONT_PATH) $(DECK) $@

clean:
	rm -rf $(BUILD_DIR)
