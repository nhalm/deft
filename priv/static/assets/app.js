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
  document.addEventListener("DOMContentLoaded", () => {
    var _a;
    const csrfToken = (_a = document.querySelector("meta[name='csrf-token']")) == null ? void 0 : _a.getAttribute("content");
    const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
      params: { _csrf_token: csrfToken },
      hooks: {
        ScrollControl,
        InputFocus,
        TextareaInput,
        SyntaxHighlight
      },
      metadata: {
        keydown: (e) => ({ ctrlKey: e.ctrlKey })
      }
    });
    liveSocket.connect();
    window.liveSocket = liveSocket;
  });
})();
//# sourceMappingURL=data:application/json;base64,ewogICJ2ZXJzaW9uIjogMywKICAic291cmNlcyI6IFsiLi4vLi4vLi4vYXNzZXRzL2pzL2FwcC5qcyJdLAogICJzb3VyY2VzQ29udGVudCI6IFsiLyoqXG4gKiBEZWZ0IExpdmVWaWV3IEphdmFTY3JpcHQgSG9va3NcbiAqXG4gKiBQcm92aWRlcyBjbGllbnQtc2lkZSBob29rcyBmb3IgTGl2ZVZpZXc6XG4gKiAtIFNjcm9sbENvbnRyb2w6IEF1dG8tc2Nyb2xsIGR1cmluZyBzdHJlYW1pbmcsIGZyZWV6ZSBvbiB1c2VyIHNjcm9sbCwgcmVzdW1lIG9uIHNjcm9sbC10by1ib3R0b21cbiAqIC0gSW5wdXRGb2N1czogRm9jdXMgaW5wdXQgb24gaW5zZXJ0IG1vZGUsIGJsdXIgb24gbm9ybWFsIG1vZGVcbiAqIC0gVGV4dGFyZWFJbnB1dDogRm9jdXMgbWFuYWdlbWVudCArIEVudGVyIHRvIHN1Ym1pdCwgU2hpZnQrRW50ZXIgZm9yIG5ld2xpbmVcbiAqXG4gKiBOb3RlOiBUaGlzIGZpbGUgaXMgY29waWVkIHRvIHByaXYvc3RhdGljL2Fzc2V0cy9hcHAuanMgZHVyaW5nIGJ1aWxkLlxuICogSXQgcmVsaWVzIG9uIHBob2VuaXguanMgYW5kIHBob2VuaXhfbGl2ZV92aWV3LmpzIGJlaW5nIGxvYWRlZCBmaXJzdC5cbiAqL1xuXG4vLyBTY3JvbGwgQ29udHJvbCBIb29rXG4vLyBNYW5hZ2VzIGF1dG8tc2Nyb2xsaW5nIGR1cmluZyBzdHJlYW1pbmcgYW5kIHVzZXIgc2Nyb2xsIGRldGVjdGlvblxuY29uc3QgU2Nyb2xsQ29udHJvbCA9IHtcbiAgbW91bnRlZCgpIHtcbiAgICB0aGlzLnVzZXJTY3JvbGxlZCA9IGZhbHNlXG4gICAgdGhpcy5pc0F0Qm90dG9tID0gdHJ1ZVxuXG4gICAgLy8gRGV0ZWN0IHVzZXIgc2Nyb2xsXG4gICAgdGhpcy5lbC5hZGRFdmVudExpc3RlbmVyKFwic2Nyb2xsXCIsICgpID0+IHtcbiAgICAgIGNvbnN0IGVsID0gdGhpcy5lbFxuICAgICAgY29uc3QgaXNOb3dBdEJvdHRvbSA9IGVsLnNjcm9sbEhlaWdodCAtIGVsLnNjcm9sbFRvcCA8PSBlbC5jbGllbnRIZWlnaHQgKyA1MCAvLyA1MHB4IHRocmVzaG9sZFxuXG4gICAgICBpZiAoaXNOb3dBdEJvdHRvbSkge1xuICAgICAgICAvLyBVc2VyIHNjcm9sbGVkIGJhY2sgdG8gYm90dG9tIC0gcmVzdW1lIGF1dG8tc2Nyb2xsXG4gICAgICAgIHRoaXMudXNlclNjcm9sbGVkID0gZmFsc2VcbiAgICAgICAgdGhpcy5pc0F0Qm90dG9tID0gdHJ1ZVxuICAgICAgfSBlbHNlIGlmICghdGhpcy51c2VyU2Nyb2xsZWQpIHtcbiAgICAgICAgLy8gVXNlciBpbml0aWF0ZWQgc2Nyb2xsIGF3YXkgZnJvbSBib3R0b21cbiAgICAgICAgdGhpcy51c2VyU2Nyb2xsZWQgPSB0cnVlXG4gICAgICAgIHRoaXMuaXNBdEJvdHRvbSA9IGZhbHNlXG4gICAgICB9XG4gICAgfSlcblxuICAgIC8vIEF1dG8tc2Nyb2xsIG9uIGNvbnRlbnQgY2hhbmdlcyAoc3RyZWFtaW5nKVxuICAgIHRoaXMub2JzZXJ2ZXIgPSBuZXcgTXV0YXRpb25PYnNlcnZlcigoKSA9PiB7XG4gICAgICAvLyBPbmx5IGF1dG8tc2Nyb2xsIGlmIHVzZXIgaGFzbid0IG1hbnVhbGx5IHNjcm9sbGVkIGF3YXlcbiAgICAgIGlmICghdGhpcy51c2VyU2Nyb2xsZWQgfHwgdGhpcy5pc0F0Qm90dG9tKSB7XG4gICAgICAgIHRoaXMuc2Nyb2xsVG9Cb3R0b20oKVxuICAgICAgfVxuICAgIH0pXG5cbiAgICB0aGlzLm9ic2VydmVyLm9ic2VydmUodGhpcy5lbCwge1xuICAgICAgY2hpbGRMaXN0OiB0cnVlLFxuICAgICAgc3VidHJlZTogdHJ1ZSxcbiAgICAgIGNoYXJhY3RlckRhdGE6IHRydWVcbiAgICB9KVxuXG4gICAgLy8gSW5pdGlhbCBzY3JvbGwgdG8gYm90dG9tXG4gICAgdGhpcy5zY3JvbGxUb0JvdHRvbSgpXG4gIH0sXG5cbiAgdXBkYXRlZCgpIHtcbiAgICAvLyBBdXRvLXNjcm9sbCBvbiBMaXZlVmlldyB1cGRhdGVzIGlmIG5vdCB1c2VyLXNjcm9sbGVkXG4gICAgaWYgKCF0aGlzLnVzZXJTY3JvbGxlZCB8fCB0aGlzLmlzQXRCb3R0b20pIHtcbiAgICAgIHRoaXMuc2Nyb2xsVG9Cb3R0b20oKVxuICAgIH1cbiAgfSxcblxuICBzY3JvbGxUb0JvdHRvbSgpIHtcbiAgICB0aGlzLmVsLnNjcm9sbFRvcCA9IHRoaXMuZWwuc2Nyb2xsSGVpZ2h0XG4gICAgdGhpcy5pc0F0Qm90dG9tID0gdHJ1ZVxuICB9LFxuXG4gIGhhbmRsZUV2ZW50KGV2ZW50LCBwYXlsb2FkKSB7XG4gICAgaWYgKGV2ZW50ID09PSBcInNjcm9sbF90b1wiKSB7XG4gICAgICBpZiAocGF5bG9hZC5wb3NpdGlvbiA9PT0gXCJib3R0b21cIikge1xuICAgICAgICAvLyBTY3JvbGwgdG8gYm90dG9tIChHIGtleSlcbiAgICAgICAgdGhpcy5lbC5zY3JvbGxUb3AgPSB0aGlzLmVsLnNjcm9sbEhlaWdodFxuICAgICAgICB0aGlzLmlzQXRCb3R0b20gPSB0cnVlXG4gICAgICAgIHRoaXMudXNlclNjcm9sbGVkID0gZmFsc2VcbiAgICAgIH0gZWxzZSBpZiAocGF5bG9hZC5wb3NpdGlvbiA9PT0gXCJ0b3BcIikge1xuICAgICAgICAvLyBTY3JvbGwgdG8gdG9wIChnZyBrZXlzKVxuICAgICAgICB0aGlzLmVsLnNjcm9sbFRvcCA9IDBcbiAgICAgICAgdGhpcy5pc0F0Qm90dG9tID0gZmFsc2VcbiAgICAgICAgdGhpcy51c2VyU2Nyb2xsZWQgPSB0cnVlXG4gICAgICB9IGVsc2UgaWYgKHBheWxvYWQuZGVsdGEgIT09IHVuZGVmaW5lZCkge1xuICAgICAgICAvLyBSZWxhdGl2ZSBzY3JvbGwgKGovay9DdHJsK3UvQ3RybCtkKVxuICAgICAgICB0aGlzLmVsLnNjcm9sbFRvcCArPSBwYXlsb2FkLmRlbHRhXG4gICAgICAgIC8vIENoZWNrIGlmIHdlJ3JlIGF0IGJvdHRvbSBhZnRlciBzY3JvbGxcbiAgICAgICAgY29uc3QgaXNOb3dBdEJvdHRvbSA9IHRoaXMuZWwuc2Nyb2xsSGVpZ2h0IC0gdGhpcy5lbC5zY3JvbGxUb3AgPD0gdGhpcy5lbC5jbGllbnRIZWlnaHQgKyA1MFxuICAgICAgICB0aGlzLmlzQXRCb3R0b20gPSBpc05vd0F0Qm90dG9tXG4gICAgICAgIHRoaXMudXNlclNjcm9sbGVkID0gIWlzTm93QXRCb3R0b21cbiAgICAgIH1cbiAgICB9XG4gIH0sXG5cbiAgZGVzdHJveWVkKCkge1xuICAgIGlmICh0aGlzLm9ic2VydmVyKSB7XG4gICAgICB0aGlzLm9ic2VydmVyLmRpc2Nvbm5lY3QoKVxuICAgIH1cbiAgfVxufVxuXG4vLyBJbnB1dCBGb2N1cyBIb29rXG4vLyBNYW5hZ2VzIGlucHV0IGZvY3VzIGJhc2VkIG9uIHZpbSBtb2RlIChpbnNlcnQgdnMgbm9ybWFsKVxuY29uc3QgSW5wdXRGb2N1cyA9IHtcbiAgbW91bnRlZCgpIHtcbiAgICAvLyBGb2N1cyBpbnB1dCBvbiBtb3VudCAoZGVmYXVsdCB0byBpbnNlcnQgbW9kZSlcbiAgICB0aGlzLmVsLmZvY3VzKClcbiAgfSxcblxuICB1cGRhdGVkKCkge1xuICAgIC8vIENoZWNrIGZvciB2aW1fbW9kZSBjaGFuZ2VzIHZpYSBkYXRhIGF0dHJpYnV0ZVxuICAgIGNvbnN0IG1vZGUgPSB0aGlzLmVsLmRhdGFzZXQudmltTW9kZVxuXG4gICAgaWYgKG1vZGUgPT09IFwiaW5zZXJ0XCIpIHtcbiAgICAgIHRoaXMuZWwuZm9jdXMoKVxuICAgIH0gZWxzZSBpZiAobW9kZSA9PT0gXCJub3JtYWxcIiB8fCBtb2RlID09PSBcImNvbW1hbmRcIikge1xuICAgICAgdGhpcy5lbC5ibHVyKClcbiAgICB9XG4gIH1cbn1cblxuLy8gVGV4dGFyZWEgSW5wdXQgSG9va1xuLy8gQ29tYmluZXMgZm9jdXMgbWFuYWdlbWVudCAodmltIG1vZGUpIGFuZCBFbnRlciBrZXkgaGFuZGxpbmcgKHN1Ym1pdCB2cyBuZXdsaW5lKVxuY29uc3QgVGV4dGFyZWFJbnB1dCA9IHtcbiAgbW91bnRlZCgpIHtcbiAgICAvLyBGb2N1cyBpbnB1dCBvbiBtb3VudCAoZGVmYXVsdCB0byBpbnNlcnQgbW9kZSlcbiAgICB0aGlzLmVsLmZvY3VzKClcblxuICAgIC8vIEhhbmRsZSBFbnRlciB0byBzdWJtaXQsIFNoaWZ0K0VudGVyIGZvciBuZXdsaW5lXG4gICAgdGhpcy5lbC5hZGRFdmVudExpc3RlbmVyKFwia2V5ZG93blwiLCAoZSkgPT4ge1xuICAgICAgaWYgKGUua2V5ID09PSBcIkVudGVyXCIgJiYgIWUuc2hpZnRLZXkpIHtcbiAgICAgICAgLy8gRW50ZXIgd2l0aG91dCBTaGlmdCAtIHN1Ym1pdCB0aGUgZm9ybVxuICAgICAgICBlLnByZXZlbnREZWZhdWx0KClcbiAgICAgICAgY29uc3QgZm9ybSA9IHRoaXMuZWwuY2xvc2VzdChcImZvcm1cIilcbiAgICAgICAgaWYgKGZvcm0pIHtcbiAgICAgICAgICAvLyBUcmlnZ2VyIG5hdGl2ZSBmb3JtIHN1Ym1pc3Npb24gKExpdmVWaWV3IGludGVyY2VwdHMgdGhpcylcbiAgICAgICAgICBmb3JtLnJlcXVlc3RTdWJtaXQoKVxuICAgICAgICB9XG4gICAgICB9XG4gICAgICAvLyBTaGlmdCtFbnRlciBhbGxvd3MgZGVmYXVsdCBiZWhhdmlvciAobmV3bGluZSlcbiAgICB9KVxuICB9LFxuXG4gIHVwZGF0ZWQoKSB7XG4gICAgLy8gQ2hlY2sgZm9yIHZpbV9tb2RlIGNoYW5nZXMgdmlhIGRhdGEgYXR0cmlidXRlXG4gICAgY29uc3QgbW9kZSA9IHRoaXMuZWwuZGF0YXNldC52aW1Nb2RlXG5cbiAgICBpZiAobW9kZSA9PT0gXCJpbnNlcnRcIikge1xuICAgICAgdGhpcy5lbC5mb2N1cygpXG4gICAgfSBlbHNlIGlmIChtb2RlID09PSBcIm5vcm1hbFwiIHx8IG1vZGUgPT09IFwiY29tbWFuZFwiKSB7XG4gICAgICB0aGlzLmVsLmJsdXIoKVxuICAgIH1cbiAgfVxufVxuXG4vLyBTeW50YXggSGlnaGxpZ2h0aW5nIEhvb2tcbi8vIEFwcGxpZXMgaGlnaGxpZ2h0LmpzIHRvIGNvZGUgYmxvY2tzIGFmdGVyIGVhY2ggTGl2ZVZpZXcgRE9NIHVwZGF0ZVxuY29uc3QgU3ludGF4SGlnaGxpZ2h0ID0ge1xuICBtb3VudGVkKCkge1xuICAgIHRoaXMuaGlnaGxpZ2h0KClcbiAgfSxcblxuICB1cGRhdGVkKCkge1xuICAgIHRoaXMuaGlnaGxpZ2h0KClcbiAgfSxcblxuICBoaWdobGlnaHQoKSB7XG4gICAgLy8gRmluZCBhbGwgY29kZSBibG9ja3Mgd2l0aGluIHRoaXMgY29udGFpbmVyIHRoYXQgaGF2ZW4ndCBiZWVuIGhpZ2hsaWdodGVkXG4gICAgY29uc3QgY29kZUJsb2NrcyA9IHRoaXMuZWwucXVlcnlTZWxlY3RvckFsbCgncHJlIGNvZGU6bm90KC5obGpzKScpXG4gICAgY29kZUJsb2Nrcy5mb3JFYWNoKChibG9jaykgPT4ge1xuICAgICAgd2luZG93LmhsanMuaGlnaGxpZ2h0RWxlbWVudChibG9jaylcbiAgICB9KVxuICB9XG59XG5cbi8vIEluaXRpYWxpemUgTGl2ZVNvY2tldCB3aGVuIERPTSBpcyByZWFkeVxuZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcihcIkRPTUNvbnRlbnRMb2FkZWRcIiwgKCkgPT4ge1xuICAvLyBHZXQgQ1NSRiB0b2tlbiBmcm9tIG1ldGEgdGFnXG4gIGNvbnN0IGNzcmZUb2tlbiA9IGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3IoXCJtZXRhW25hbWU9J2NzcmYtdG9rZW4nXVwiKT8uZ2V0QXR0cmlidXRlKFwiY29udGVudFwiKVxuXG4gIC8vIENyZWF0ZSBMaXZlU29ja2V0IHdpdGggaG9va3NcbiAgY29uc3QgbGl2ZVNvY2tldCA9IG5ldyB3aW5kb3cuTGl2ZVZpZXcuTGl2ZVNvY2tldChcIi9saXZlXCIsIHdpbmRvdy5QaG9lbml4LlNvY2tldCwge1xuICAgIHBhcmFtczogeyBfY3NyZl90b2tlbjogY3NyZlRva2VuIH0sXG4gICAgaG9va3M6IHtcbiAgICAgIFNjcm9sbENvbnRyb2wsXG4gICAgICBJbnB1dEZvY3VzLFxuICAgICAgVGV4dGFyZWFJbnB1dCxcbiAgICAgIFN5bnRheEhpZ2hsaWdodFxuICAgIH0sXG4gICAgbWV0YWRhdGE6IHtcbiAgICAgIGtleWRvd246IChlKSA9PiAoeyBjdHJsS2V5OiBlLmN0cmxLZXkgfSlcbiAgICB9XG4gIH0pXG5cbiAgLy8gQ29ubmVjdCB0byBMaXZlVmlld1xuICBsaXZlU29ja2V0LmNvbm5lY3QoKVxuXG4gIC8vIEV4cG9zZSBmb3IgZGVidWdnaW5nIGluIGRldlxuICB3aW5kb3cubGl2ZVNvY2tldCA9IGxpdmVTb2NrZXRcbn0pXG4iXSwKICAibWFwcGluZ3MiOiAiOztBQWNBLE1BQU0sZ0JBQWdCO0FBQUEsSUFDcEIsVUFBVTtBQUNSLFdBQUssZUFBZTtBQUNwQixXQUFLLGFBQWE7QUFHbEIsV0FBSyxHQUFHLGlCQUFpQixVQUFVLE1BQU07QUFDdkMsY0FBTSxLQUFLLEtBQUs7QUFDaEIsY0FBTSxnQkFBZ0IsR0FBRyxlQUFlLEdBQUcsYUFBYSxHQUFHLGVBQWU7QUFFMUUsWUFBSSxlQUFlO0FBRWpCLGVBQUssZUFBZTtBQUNwQixlQUFLLGFBQWE7QUFBQSxRQUNwQixXQUFXLENBQUMsS0FBSyxjQUFjO0FBRTdCLGVBQUssZUFBZTtBQUNwQixlQUFLLGFBQWE7QUFBQSxRQUNwQjtBQUFBLE1BQ0YsQ0FBQztBQUdELFdBQUssV0FBVyxJQUFJLGlCQUFpQixNQUFNO0FBRXpDLFlBQUksQ0FBQyxLQUFLLGdCQUFnQixLQUFLLFlBQVk7QUFDekMsZUFBSyxlQUFlO0FBQUEsUUFDdEI7QUFBQSxNQUNGLENBQUM7QUFFRCxXQUFLLFNBQVMsUUFBUSxLQUFLLElBQUk7QUFBQSxRQUM3QixXQUFXO0FBQUEsUUFDWCxTQUFTO0FBQUEsUUFDVCxlQUFlO0FBQUEsTUFDakIsQ0FBQztBQUdELFdBQUssZUFBZTtBQUFBLElBQ3RCO0FBQUEsSUFFQSxVQUFVO0FBRVIsVUFBSSxDQUFDLEtBQUssZ0JBQWdCLEtBQUssWUFBWTtBQUN6QyxhQUFLLGVBQWU7QUFBQSxNQUN0QjtBQUFBLElB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
