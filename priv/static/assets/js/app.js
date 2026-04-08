(() => {
  // js/app.js
  var ScrollControl = {
    mounted() {
      this.userScrolled = false;
      this.isAtBottom = true;
      this.el.addEventListener("scroll", () => {
        const el = this.el;
        const isNowAtBottom = el.scrollHeight - el.scrollTop <= el.clientHeight + 50;
        if (isNowAtBottom) {
          this.userScrolled = false;
          this.isAtBottom = true;
        } else if (!this.userScrolled) {
          this.userScrolled = true;
          this.isAtBottom = false;
        }
      });
      this.observer = new MutationObserver(() => {
        if (!this.userScrolled || this.isAtBottom) {
          this.scrollToBottom();
        }
      });
      this.observer.observe(this.el, {
        childList: true,
        subtree: true,
        characterData: true
      });
      this.scrollToBottom();
    },
    updated() {
      if (!this.userScrolled || this.isAtBottom) {
        this.scrollToBottom();
      }
    },
    scrollToBottom() {
      this.el.scrollTop = this.el.scrollHeight;
      this.isAtBottom = true;
    },
    handleEvent(event, payload) {
      if (event === "scroll_to") {
        if (payload.position === "bottom") {
          this.el.scrollTop = this.el.scrollHeight;
          this.isAtBottom = true;
          this.userScrolled = false;
        } else if (payload.position === "top") {
          this.el.scrollTop = 0;
          this.isAtBottom = false;
          this.userScrolled = true;
        } else if (payload.delta !== void 0) {
          this.el.scrollTop += payload.delta;
          const isNowAtBottom = this.el.scrollHeight - this.el.scrollTop <= this.el.clientHeight + 50;
          this.isAtBottom = isNowAtBottom;
          this.userScrolled = !isNowAtBottom;
        }
      }
    },
    destroyed() {
      if (this.observer) {
        this.observer.disconnect();
      }
    }
  };
  var InputFocus = {
    mounted() {
      this.el.focus();
    },
    updated() {
      const mode = this.el.dataset.vimMode;
      if (mode === "insert") {
        this.el.focus();
      } else if (mode === "normal" || mode === "command") {
        this.el.blur();
      }
    }
  };
  var TextareaInput = {
    mounted() {
      this.el.focus();
      this.el.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && !e.shiftKey) {
          e.preventDefault();
          const form = this.el.closest("form");
          if (form) {
            form.requestSubmit();
          }
        }
      });
    },
    updated() {
      const mode = this.el.dataset.vimMode;
      if (mode === "insert") {
        this.el.focus();
      } else if (mode === "normal" || mode === "command") {
        this.el.blur();
      }
    }
  };
  var SyntaxHighlight = {
    mounted() {
      this.highlight();
    },
    updated() {
      this.highlight();
    },
    highlight() {
      const codeBlocks = this.el.querySelectorAll("pre code:not(.hljs)");
      codeBlocks.forEach((block) => {
        window.hljs.highlightElement(block);
      });
    }
  };
  var StreamingMarkdown = {
    mounted() {
      this.contentEl = this.el.querySelector(".streaming-markdown-content");
      this.handleEvent("streaming_markdown", ({ html }) => {
        if (this.contentEl) {
          this.contentEl.innerHTML = html;
        }
      });
    }
  };
  function escapeHtml(text) {
    if (!text)
      return "";
    return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
  window.toggleToolDetail = function(toolId) {
    const el = document.getElementById(toolId);
    if (!el)
      return;
    const details = document.getElementById(toolId + "-details");
    if (!details)
      return;
    if (details.dataset.loaded) {
      el.classList.toggle("expanded");
      details.classList.toggle("hidden");
      return;
    }
    const sessionId = el.dataset.sessionId;
    const toolCallId = el.dataset.toolCallId;
    if (!sessionId || !toolCallId) {
      details.innerHTML = '<p class="tool-detail-label">No details available.</p>';
      details.dataset.loaded = "true";
      details.classList.remove("hidden");
      el.classList.add("expanded");
      return;
    }
    details.innerHTML = '<p class="tool-detail-label">Loading...</p>';
    details.classList.remove("hidden");
    el.classList.add("expanded");
    fetch(`/api/tool_detail/${sessionId}/${toolCallId}`).then((r) => r.json()).then((data) => {
      let html = "";
      if (data.input) {
        html += `<div class="tool-detail-section"><div class="tool-detail-label">Input:</div><pre class="tool-detail-pre">${escapeHtml(data.input)}</pre></div>`;
      }
      if (data.output) {
        html += `<div class="tool-detail-section"><div class="tool-detail-label">Output:</div><pre class="tool-detail-pre">${escapeHtml(data.output)}</pre></div>`;
      }
      if (!data.input && !data.output) {
        html = '<p class="tool-detail-label">No details available.</p>';
      }
      details.innerHTML = html;
      details.dataset.loaded = "true";
    }).catch(() => {
      details.innerHTML = '<p class="tool-detail-label">Failed to load details.</p>';
      details.dataset.loaded = "true";
    });
  };
  var OpenSession = {
    mounted() {
      this.handleEvent("open_session", ({ url }) => {
        window.open(url, "_blank");
      });
    }
  };
  document.addEventListener("DOMContentLoaded", () => {
    var _a;
    const csrfToken = (_a = document.querySelector("meta[name='csrf-token']")) == null ? void 0 : _a.getAttribute("content");
    const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
      params: { _csrf_token: csrfToken },
      hooks: {
        ScrollControl,
        InputFocus,
        TextareaInput,
        SyntaxHighlight,
        StreamingMarkdown,
        OpenSession
      },
      metadata: {
        keydown: (e) => ({ ctrlKey: e.ctrlKey })
      }
    });
    liveSocket.connect();
    window.liveSocket = liveSocket;
  });
})();
//# sourceMappingURL=data:application/json;base64,ewogICJ2ZXJzaW9uIjogMywKICAic291cmNlcyI6IFsiLi4vLi4vLi4vLi4vYXNzZXRzL2pzL2FwcC5qcyJdLAogICJzb3VyY2VzQ29udGVudCI6IFsiLyoqXG4gKiBEZWZ0IExpdmVWaWV3IEphdmFTY3JpcHQgSG9va3NcbiAqXG4gKiBQcm92aWRlcyBjbGllbnQtc2lkZSBob29rcyBmb3IgTGl2ZVZpZXc6XG4gKiAtIFNjcm9sbENvbnRyb2w6IEF1dG8tc2Nyb2xsIGR1cmluZyBzdHJlYW1pbmcsIGZyZWV6ZSBvbiB1c2VyIHNjcm9sbCwgcmVzdW1lIG9uIHNjcm9sbC10by1ib3R0b21cbiAqIC0gSW5wdXRGb2N1czogRm9jdXMgaW5wdXQgb24gaW5zZXJ0IG1vZGUsIGJsdXIgb24gbm9ybWFsIG1vZGVcbiAqIC0gVGV4dGFyZWFJbnB1dDogRm9jdXMgbWFuYWdlbWVudCArIEVudGVyIHRvIHN1Ym1pdCwgU2hpZnQrRW50ZXIgZm9yIG5ld2xpbmVcbiAqXG4gKiBOb3RlOiBUaGlzIGZpbGUgaXMgY29waWVkIHRvIHByaXYvc3RhdGljL2Fzc2V0cy9hcHAuanMgZHVyaW5nIGJ1aWxkLlxuICogSXQgcmVsaWVzIG9uIHBob2VuaXguanMgYW5kIHBob2VuaXhfbGl2ZV92aWV3LmpzIGJlaW5nIGxvYWRlZCBmaXJzdC5cbiAqL1xuXG4vLyBTY3JvbGwgQ29udHJvbCBIb29rXG4vLyBNYW5hZ2VzIGF1dG8tc2Nyb2xsaW5nIGR1cmluZyBzdHJlYW1pbmcgYW5kIHVzZXIgc2Nyb2xsIGRldGVjdGlvblxuY29uc3QgU2Nyb2xsQ29udHJvbCA9IHtcbiAgbW91bnRlZCgpIHtcbiAgICB0aGlzLnVzZXJTY3JvbGxlZCA9IGZhbHNlXG4gICAgdGhpcy5pc0F0Qm90dG9tID0gdHJ1ZVxuXG4gICAgLy8gRGV0ZWN0IHVzZXIgc2Nyb2xsXG4gICAgdGhpcy5lbC5hZGRFdmVudExpc3RlbmVyKFwic2Nyb2xsXCIsICgpID0+IHtcbiAgICAgIGNvbnN0IGVsID0gdGhpcy5lbFxuICAgICAgY29uc3QgaXNOb3dBdEJvdHRvbSA9IGVsLnNjcm9sbEhlaWdodCAtIGVsLnNjcm9sbFRvcCA8PSBlbC5jbGllbnRIZWlnaHQgKyA1MCAvLyA1MHB4IHRocmVzaG9sZFxuXG4gICAgICBpZiAoaXNOb3dBdEJvdHRvbSkge1xuICAgICAgICAvLyBVc2VyIHNjcm9sbGVkIGJhY2sgdG8gYm90dG9tIC0gcmVzdW1lIGF1dG8tc2Nyb2xsXG4gICAgICAgIHRoaXMudXNlclNjcm9sbGVkID0gZmFsc2VcbiAgICAgICAgdGhpcy5pc0F0Qm90dG9tID0gdHJ1ZVxuICAgICAgfSBlbHNlIGlmICghdGhpcy51c2VyU2Nyb2xsZWQpIHtcbiAgICAgICAgLy8gVXNlciBpbml0aWF0ZWQgc2Nyb2xsIGF3YXkgZnJvbSBib3R0b21cbiAgICAgICAgdGhpcy51c2VyU2Nyb2xsZWQgPSB0cnVlXG4gICAgICAgIHRoaXMuaXNBdEJvdHRvbSA9IGZhbHNlXG4gICAgICB9XG4gICAgfSlcblxuICAgIC8vIEF1dG8tc2Nyb2xsIG9uIGNvbnRlbnQgY2hhbmdlcyAoc3RyZWFtaW5nKVxuICAgIHRoaXMub2JzZXJ2ZXIgPSBuZXcgTXV0YXRpb25PYnNlcnZlcigoKSA9PiB7XG4gICAgICAvLyBPbmx5IGF1dG8tc2Nyb2xsIGlmIHVzZXIgaGFzbid0IG1hbnVhbGx5IHNjcm9sbGVkIGF3YXlcbiAgICAgIGlmICghdGhpcy51c2VyU2Nyb2xsZWQgfHwgdGhpcy5pc0F0Qm90dG9tKSB7XG4gICAgICAgIHRoaXMuc2Nyb2xsVG9Cb3R0b20oKVxuICAgICAgfVxuICAgIH0pXG5cbiAgICB0aGlzLm9ic2VydmVyLm9ic2VydmUodGhpcy5lbCwge1xuICAgICAgY2hpbGRMaXN0OiB0cnVlLFxuICAgICAgc3VidHJlZTogdHJ1ZSxcbiAgICAgIGNoYXJhY3RlckRhdGE6IHRydWVcbiAgICB9KVxuXG4gICAgLy8gSW5pdGlhbCBzY3JvbGwgdG8gYm90dG9tXG4gICAgdGhpcy5zY3JvbGxUb0JvdHRvbSgpXG4gIH0sXG5cbiAgdXBkYXRlZCgpIHtcbiAgICAvLyBBdXRvLXNjcm9sbCBvbiBMaXZlVmlldyB1cGRhdGVzIGlmIG5vdCB1c2VyLXNjcm9sbGVkXG4gICAgaWYgKCF0aGlzLnVzZXJTY3JvbGxlZCB8fCB0aGlzLmlzQXRCb3R0b20pIHtcbiAgICAgIHRoaXMuc2Nyb2xsVG9Cb3R0b20oKVxuICAgIH1cbiAgfSxcblxuICBzY3JvbGxUb0JvdHRvbSgpIHtcbiAgICB0aGlzLmVsLnNjcm9sbFRvcCA9IHRoaXMuZWwuc2Nyb2xsSGVpZ2h0XG4gICAgdGhpcy5pc0F0Qm90dG9tID0gdHJ1ZVxuICB9LFxuXG4gIGhhbmRsZUV2ZW50KGV2ZW50LCBwYXlsb2FkKSB7XG4gICAgaWYgKGV2ZW50ID09PSBcInNjcm9sbF90b1wiKSB7XG4gICAgICBpZiAocGF5bG9hZC5wb3NpdGlvbiA9PT0gXCJib3R0b21cIikge1xuICAgICAgICAvLyBTY3JvbGwgdG8gYm90dG9tIChHIGtleSlcbiAgICAgICAgdGhpcy5lbC5zY3JvbGxUb3AgPSB0aGlzLmVsLnNjcm9sbEhlaWdodFxuICAgICAgICB0aGlzLmlzQXRCb3R0b20gPSB0cnVlXG4gICAgICAgIHRoaXMudXNlclNjcm9sbGVkID0gZmFsc2VcbiAgICAgIH0gZWxzZSBpZiAocGF5bG9hZC5wb3NpdGlvbiA9PT0gXCJ0b3BcIikge1xuICAgICAgICAvLyBTY3JvbGwgdG8gdG9wIChnZyBrZXlzKVxuICAgICAgICB0aGlzLmVsLnNjcm9sbFRvcCA9IDBcbiAgICAgICAgdGhpcy5pc0F0Qm90dG9tID0gZmFsc2VcbiAgICAgICAgdGhpcy51c2VyU2Nyb2xsZWQgPSB0cnVlXG4gICAgICB9IGVsc2UgaWYgKHBheWxvYWQuZGVsdGEgIT09IHVuZGVmaW5lZCkge1xuICAgICAgICAvLyBSZWxhdGl2ZSBzY3JvbGwgKGovay9DdHJsK3UvQ3RybCtkKVxuICAgICAgICB0aGlzLmVsLnNjcm9sbFRvcCArPSBwYXlsb2FkLmRlbHRhXG4gICAgICAgIC8vIENoZWNrIGlmIHdlJ3JlIGF0IGJvdHRvbSBhZnRlciBzY3JvbGxcbiAgICAgICAgY29uc3QgaXNOb3dBdEJvdHRvbSA9IHRoaXMuZWwuc2Nyb2xsSGVpZ2h0IC0gdGhpcy5lbC5zY3JvbGxUb3AgPD0gdGhpcy5lbC5jbGllbnRIZWlnaHQgKyA1MFxuICAgICAgICB0aGlzLmlzQXRCb3R0b20gPSBpc05vd0F0Qm90dG9tXG4gICAgICAgIHRoaXMudXNlclNjcm9sbGVkID0gIWlzTm93QXRCb3R0b21cbiAgICAgIH1cbiAgICB9XG4gIH0sXG5cbiAgZGVzdHJveWVkKCkge1xuICAgIGlmICh0aGlzLm9ic2VydmVyKSB7XG4gICAgICB0aGlzLm9ic2VydmVyLmRpc2Nvbm5lY3QoKVxuICAgIH1cbiAgfVxufVxuXG4vLyBJbnB1dCBGb2N1cyBIb29rXG4vLyBNYW5hZ2VzIGlucHV0IGZvY3VzIGJhc2VkIG9uIHZpbSBtb2RlIChpbnNlcnQgdnMgbm9ybWFsKVxuY29uc3QgSW5wdXRGb2N1cyA9IHtcbiAgbW91bnRlZCgpIHtcbiAgICAvLyBGb2N1cyBpbnB1dCBvbiBtb3VudCAoZGVmYXVsdCB0byBpbnNlcnQgbW9kZSlcbiAgICB0aGlzLmVsLmZvY3VzKClcbiAgfSxcblxuICB1cGRhdGVkKCkge1xuICAgIC8vIENoZWNrIGZvciB2aW1fbW9kZSBjaGFuZ2VzIHZpYSBkYXRhIGF0dHJpYnV0ZVxuICAgIGNvbnN0IG1vZGUgPSB0aGlzLmVsLmRhdGFzZXQudmltTW9kZVxuXG4gICAgaWYgKG1vZGUgPT09IFwiaW5zZXJ0XCIpIHtcbiAgICAgIHRoaXMuZWwuZm9jdXMoKVxuICAgIH0gZWxzZSBpZiAobW9kZSA9PT0gXCJub3JtYWxcIiB8fCBtb2RlID09PSBcImNvbW1hbmRcIikge1xuICAgICAgdGhpcy5lbC5ibHVyKClcbiAgICB9XG4gIH1cbn1cblxuLy8gVGV4dGFyZWEgSW5wdXQgSG9va1xuLy8gQ29tYmluZXMgZm9jdXMgbWFuYWdlbWVudCAodmltIG1vZGUpIGFuZCBFbnRlciBrZXkgaGFuZGxpbmcgKHN1Ym1pdCB2cyBuZXdsaW5lKVxuY29uc3QgVGV4dGFyZWFJbnB1dCA9IHtcbiAgbW91bnRlZCgpIHtcbiAgICAvLyBGb2N1cyBpbnB1dCBvbiBtb3VudCAoZGVmYXVsdCB0byBpbnNlcnQgbW9kZSlcbiAgICB0aGlzLmVsLmZvY3VzKClcblxuICAgIC8vIEhhbmRsZSBFbnRlciB0byBzdWJtaXQsIFNoaWZ0K0VudGVyIGZvciBuZXdsaW5lXG4gICAgdGhpcy5lbC5hZGRFdmVudExpc3RlbmVyKFwia2V5ZG93blwiLCAoZSkgPT4ge1xuICAgICAgaWYgKGUua2V5ID09PSBcIkVudGVyXCIgJiYgIWUuc2hpZnRLZXkpIHtcbiAgICAgICAgLy8gRW50ZXIgd2l0aG91dCBTaGlmdCAtIHN1Ym1pdCB0aGUgZm9ybVxuICAgICAgICBlLnByZXZlbnREZWZhdWx0KClcbiAgICAgICAgY29uc3QgZm9ybSA9IHRoaXMuZWwuY2xvc2VzdChcImZvcm1cIilcbiAgICAgICAgaWYgKGZvcm0pIHtcbiAgICAgICAgICAvLyBUcmlnZ2VyIG5hdGl2ZSBmb3JtIHN1Ym1pc3Npb24gKExpdmVWaWV3IGludGVyY2VwdHMgdGhpcylcbiAgICAgICAgICBmb3JtLnJlcXVlc3RTdWJtaXQoKVxuICAgICAgICB9XG4gICAgICB9XG4gICAgICAvLyBTaGlmdCtFbnRlciBhbGxvd3MgZGVmYXVsdCBiZWhhdmlvciAobmV3bGluZSlcbiAgICB9KVxuICB9LFxuXG4gIHVwZGF0ZWQoKSB7XG4gICAgLy8gQ2hlY2sgZm9yIHZpbV9tb2RlIGNoYW5nZXMgdmlhIGRhdGEgYXR0cmlidXRlXG4gICAgY29uc3QgbW9kZSA9IHRoaXMuZWwuZGF0YXNldC52aW1Nb2RlXG5cbiAgICBpZiAobW9kZSA9PT0gXCJpbnNlcnRcIikge1xuICAgICAgdGhpcy5lbC5mb2N1cygpXG4gICAgfSBlbHNlIGlmIChtb2RlID09PSBcIm5vcm1hbFwiIHx8IG1vZGUgPT09IFwiY29tbWFuZFwiKSB7XG4gICAgICB0aGlzLmVsLmJsdXIoKVxuICAgIH1cbiAgfVxufVxuXG4vLyBTeW50YXggSGlnaGxpZ2h0aW5nIEhvb2tcbi8vIEFwcGxpZXMgaGlnaGxpZ2h0LmpzIHRvIGNvZGUgYmxvY2tzIGFmdGVyIGVhY2ggTGl2ZVZpZXcgRE9NIHVwZGF0ZVxuY29uc3QgU3ludGF4SGlnaGxpZ2h0ID0ge1xuICBtb3VudGVkKCkge1xuICAgIHRoaXMuaGlnaGxpZ2h0KClcbiAgfSxcblxuICB1cGRhdGVkKCkge1xuICAgIHRoaXMuaGlnaGxpZ2h0KClcbiAgfSxcblxuICBoaWdobGlnaHQoKSB7XG4gICAgLy8gRmluZCBhbGwgY29kZSBibG9ja3Mgd2l0aGluIHRoaXMgY29udGFpbmVyIHRoYXQgaGF2ZW4ndCBiZWVuIGhpZ2hsaWdodGVkXG4gICAgY29uc3QgY29kZUJsb2NrcyA9IHRoaXMuZWwucXVlcnlTZWxlY3RvckFsbCgncHJlIGNvZGU6bm90KC5obGpzKScpXG4gICAgY29kZUJsb2Nrcy5mb3JFYWNoKChibG9jaykgPT4ge1xuICAgICAgd2luZG93LmhsanMuaGlnaGxpZ2h0RWxlbWVudChibG9jaylcbiAgICB9KVxuICB9XG59XG5cbi8vIFN0cmVhbWluZ01hcmtkb3duIEhvb2tcbi8vIFJlbmRlcnMgbWFya2Rvd24gdG8gSFRNTCBjbGllbnQtc2lkZSBkdXJpbmcgc3RyZWFtaW5nIHRvIGF2b2lkIExpdmVWaWV3IERPTSBwYXRjaGluZyBpc3N1ZXNcbmNvbnN0IFN0cmVhbWluZ01hcmtkb3duID0ge1xuICBtb3VudGVkKCkge1xuICAgIHRoaXMuY29udGVudEVsID0gdGhpcy5lbC5xdWVyeVNlbGVjdG9yKCcuc3RyZWFtaW5nLW1hcmtkb3duLWNvbnRlbnQnKVxuICAgIHRoaXMuaGFuZGxlRXZlbnQoXCJzdHJlYW1pbmdfbWFya2Rvd25cIiwgKHsgaHRtbCB9KSA9PiB7XG4gICAgICBpZiAodGhpcy5jb250ZW50RWwpIHtcbiAgICAgICAgdGhpcy5jb250ZW50RWwuaW5uZXJIVE1MID0gaHRtbFxuICAgICAgfVxuICAgIH0pXG4gIH1cbn1cblxuZnVuY3Rpb24gZXNjYXBlSHRtbCh0ZXh0KSB7XG4gIGlmICghdGV4dCkgcmV0dXJuICcnXG4gIHJldHVybiB0ZXh0LnJlcGxhY2UoLyYvZywgJyZhbXA7JykucmVwbGFjZSgvPC9nLCAnJmx0OycpLnJlcGxhY2UoLz4vZywgJyZndDsnKVxufVxuXG4vLyBUb29sIGRldGFpbCBcdTIwMTQgZmV0Y2hlcyBmcm9tIC9hcGkvdG9vbF9kZXRhaWwgb24gZmlyc3QgY2xpY2ssIHRoZW4gdG9nZ2xlc1xud2luZG93LnRvZ2dsZVRvb2xEZXRhaWwgPSBmdW5jdGlvbih0b29sSWQpIHtcbiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCh0b29sSWQpXG4gIGlmICghZWwpIHJldHVyblxuXG4gIGNvbnN0IGRldGFpbHMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCh0b29sSWQgKyAnLWRldGFpbHMnKVxuICBpZiAoIWRldGFpbHMpIHJldHVyblxuXG4gIC8vIElmIGFscmVhZHkgbG9hZGVkLCBqdXN0IHRvZ2dsZVxuICBpZiAoZGV0YWlscy5kYXRhc2V0LmxvYWRlZCkge1xuICAgIGVsLmNsYXNzTGlzdC50b2dnbGUoJ2V4cGFuZGVkJylcbiAgICBkZXRhaWxzLmNsYXNzTGlzdC50b2dnbGUoJ2hpZGRlbicpXG4gICAgcmV0dXJuXG4gIH1cblxuICBjb25zdCBzZXNzaW9uSWQgPSBlbC5kYXRhc2V0LnNlc3Npb25JZFxuICBjb25zdCB0b29sQ2FsbElkID0gZWwuZGF0YXNldC50b29sQ2FsbElkXG5cbiAgaWYgKCFzZXNzaW9uSWQgfHwgIXRvb2xDYWxsSWQpIHtcbiAgICBkZXRhaWxzLmlubmVySFRNTCA9ICc8cCBjbGFzcz1cInRvb2wtZGV0YWlsLWxhYmVsXCI+Tm8gZGV0YWlscyBhdmFpbGFibGUuPC9wPidcbiAgICBkZXRhaWxzLmRhdGFzZXQubG9hZGVkID0gJ3RydWUnXG4gICAgZGV0YWlscy5jbGFzc0xpc3QucmVtb3ZlKCdoaWRkZW4nKVxuICAgIGVsLmNsYXNzTGlzdC5hZGQoJ2V4cGFuZGVkJylcbiAgICByZXR1cm5cbiAgfVxuXG4gIC8vIFNob3cgbG9hZGluZyBzdGF0ZVxuICBkZXRhaWxzLmlubmVySFRNTCA9ICc8cCBjbGFzcz1cInRvb2wtZGV0YWlsLWxhYmVsXCI+TG9hZGluZy4uLjwvcD4nXG4gIGRldGFpbHMuY2xhc3NMaXN0LnJlbW92ZSgnaGlkZGVuJylcbiAgZWwuY2xhc3NMaXN0LmFkZCgnZXhwYW5kZWQnKVxuXG4gIGZldGNoKGAvYXBpL3Rvb2xfZGV0YWlsLyR7c2Vzc2lvbklkfS8ke3Rvb2xDYWxsSWR9YClcbiAgICAudGhlbihyID0+IHIuanNvbigpKVxuICAgIC50aGVuKGRhdGEgPT4ge1xuICAgICAgbGV0IGh0bWwgPSAnJ1xuICAgICAgaWYgKGRhdGEuaW5wdXQpIHtcbiAgICAgICAgaHRtbCArPSBgPGRpdiBjbGFzcz1cInRvb2wtZGV0YWlsLXNlY3Rpb25cIj48ZGl2IGNsYXNzPVwidG9vbC1kZXRhaWwtbGFiZWxcIj5JbnB1dDo8L2Rpdj48cHJlIGNsYXNzPVwidG9vbC1kZXRhaWwtcHJlXCI+JHtlc2NhcGVIdG1sKGRhdGEuaW5wdXQpfTwvcHJlPjwvZGl2PmBcbiAgICAgIH1cbiAgICAgIGlmIChkYXRhLm91dHB1dCkge1xuICAgICAgICBodG1sICs9IGA8ZGl2IGNsYXNzPVwidG9vbC1kZXRhaWwtc2VjdGlvblwiPjxkaXYgY2xhc3M9XCJ0b29sLWRldGFpbC1sYWJlbFwiPk91dHB1dDo8L2Rpdj48cHJlIGNsYXNzPVwidG9vbC1kZXRhaWwtcHJlXCI+JHtlc2NhcGVIdG1sKGRhdGEub3V0cHV0KX08L3ByZT48L2Rpdj5gXG4gICAgICB9XG4gICAgICBpZiAoIWRhdGEuaW5wdXQgJiYgIWRhdGEub3V0cHV0KSB7XG4gICAgICAgIGh0bWwgPSAnPHAgY2xhc3M9XCJ0b29sLWRldGFpbC1sYWJlbFwiPk5vIGRldGFpbHMgYXZhaWxhYmxlLjwvcD4nXG4gICAgICB9XG4gICAgICBkZXRhaWxzLmlubmVySFRNTCA9IGh0bWxcbiAgICAgIGRldGFpbHMuZGF0YXNldC5sb2FkZWQgPSAndHJ1ZSdcbiAgICB9KVxuICAgIC5jYXRjaCgoKSA9PiB7XG4gICAgICBkZXRhaWxzLmlubmVySFRNTCA9ICc8cCBjbGFzcz1cInRvb2wtZGV0YWlsLWxhYmVsXCI+RmFpbGVkIHRvIGxvYWQgZGV0YWlscy48L3A+J1xuICAgICAgZGV0YWlscy5kYXRhc2V0LmxvYWRlZCA9ICd0cnVlJ1xuICAgIH0pXG59XG5cbi8vIE9wZW5TZXNzaW9uIEhvb2tcbi8vIE9wZW5zIGEgc2Vzc2lvbiBpbiBhIG5ldyBicm93c2VyIHRhYiB3aGVuIHRoZSBzZXJ2ZXIgcHVzaGVzIGFuIFwib3Blbl9zZXNzaW9uXCIgZXZlbnRcbmNvbnN0IE9wZW5TZXNzaW9uID0ge1xuICBtb3VudGVkKCkge1xuICAgIHRoaXMuaGFuZGxlRXZlbnQoXCJvcGVuX3Nlc3Npb25cIiwgKHsgdXJsIH0pID0+IHtcbiAgICAgIHdpbmRvdy5vcGVuKHVybCwgXCJfYmxhbmtcIilcbiAgICB9KVxuICB9XG59XG5cbi8vIEluaXRpYWxpemUgTGl2ZVNvY2tldCB3aGVuIERPTSBpcyByZWFkeVxuZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcihcIkRPTUNvbnRlbnRMb2FkZWRcIiwgKCkgPT4ge1xuICAvLyBHZXQgQ1NSRiB0b2tlbiBmcm9tIG1ldGEgdGFnXG4gIGNvbnN0IGNzcmZUb2tlbiA9IGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3IoXCJtZXRhW25hbWU9J2NzcmYtdG9rZW4nXVwiKT8uZ2V0QXR0cmlidXRlKFwiY29udGVudFwiKVxuXG4gIC8vIENyZWF0ZSBMaXZlU29ja2V0IHdpdGggaG9va3NcbiAgY29uc3QgbGl2ZVNvY2tldCA9IG5ldyB3aW5kb3cuTGl2ZVZpZXcuTGl2ZVNvY2tldChcIi9saXZlXCIsIHdpbmRvdy5QaG9lbml4LlNvY2tldCwge1xuICAgIHBhcmFtczogeyBfY3NyZl90b2tlbjogY3NyZlRva2VuIH0sXG4gICAgaG9va3M6IHtcbiAgICAgIFNjcm9sbENvbnRyb2wsXG4gICAgICBJbnB1dEZvY3VzLFxuICAgICAgVGV4dGFyZWFJbnB1dCxcbiAgICAgIFN5bnRheEhpZ2hsaWdodCxcbiAgICAgIFN0cmVhbWluZ01hcmtkb3duLFxuICAgICAgT3BlblNlc3Npb25cbiAgICB9LFxuICAgIG1ldGFkYXRhOiB7XG4gICAgICBrZXlkb3duOiAoZSkgPT4gKHsgY3RybEtleTogZS5jdHJsS2V5IH0pXG4gICAgfVxuICB9KVxuXG4gIC8vIENvbm5lY3QgdG8gTGl2ZVZpZXdcbiAgbGl2ZVNvY2tldC5jb25uZWN0KClcblxuICAvLyBFeHBvc2UgZm9yIGRlYnVnZ2luZyBpbiBkZXZcbiAgd2luZG93LmxpdmVTb2NrZXQgPSBsaXZlU29ja2V0XG59KVxuIl0sCiAgIm1hcHBpbmdzIjogIjs7QUFjQSxNQUFNLGdCQUFnQjtBQUFBLElBQ3BCLFVBQVU7QUFDUixXQUFLLGVBQWU7QUFDcEIsV0FBSyxhQUFhO0FBR2xCLFdBQUssR0FBRyxpQkFBaUIsVUFBVSxNQUFNO0FBQ3ZDLGNBQU0sS0FBSyxLQUFLO0FBQ2hCLGNBQU0sZ0JBQWdCLEdBQUcsZUFBZSxHQUFHLGFBQWEsR0FBRyxlQUFlO0FBRTFFLFlBQUksZUFBZTtBQUVqQixlQUFLLGVBQWU7QUFDcEIsZUFBSyxhQUFhO0FBQUEsUUFDcEIsV0FBVyxDQUFDLEtBQUssY0FBYztBQUU3QixlQUFLLGVBQWU7QUFDcEIsZUFBSyxhQUFhO0FBQUEsUUFDcEI7QUFBQSxNQUNGLENBQUM7QUFHRCxXQUFLLFdBQVcsSUFBSSxpQkFBaUIsTUFBTTtBQUV6QyxZQUFJLENBQUMsS0FBSyxnQkFBZ0IsS0FBSyxZQUFZO0FBQ3pDLGVBQUssZUFBZTtBQUFBLFFBQ3RCO0FBQUEsTUFDRixDQUFDO0FBRUQsV0FBSyxTQUFTLFFBQVEsS0FBSyxJQUFJO0FBQUEsUUFDN0IsV0FBVztBQUFBLFFBQ1gsU0FBUztBQUFBLFFBQ1QsZUFBZTtBQUFBLE1BQ2pCLENBQUM7QUFHRCxXQUFLLGVBQWU7QUFBQSxJQUN0QjtBQUFBLElBRUEsVUFBVTtBQUVSLFVBQUksQ0FBQyxLQUFLLGdCQUFnQixLQUFLLFlBQVk7QUFDekMsYUFBSyxlQUFlO0FBQUEsTUFDdEI7QUFBQSxJ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
