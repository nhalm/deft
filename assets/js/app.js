/**
 * Deft LiveView JavaScript Hooks
 *
 * Provides client-side hooks for LiveView:
 * - ScrollControl: Auto-scroll during streaming, freeze on user scroll, resume on scroll-to-bottom
 * - InputFocus: Focus input on insert mode, blur on normal mode
 * - TextareaInput: Focus management + Enter to submit, Shift+Enter for newline
 *
 * Note: This file is copied to priv/static/assets/app.js during build.
 * It relies on phoenix.js and phoenix_live_view.js being loaded first.
 */

// Scroll Control Hook
// Manages auto-scrolling during streaming and user scroll detection
const ScrollControl = {
  mounted() {
    this.userScrolled = false
    this.isAtBottom = true

    // Detect user scroll
    this.el.addEventListener("scroll", () => {
      const el = this.el
      const isNowAtBottom = el.scrollHeight - el.scrollTop <= el.clientHeight + 50 // 50px threshold

      if (isNowAtBottom) {
        // User scrolled back to bottom - resume auto-scroll
        this.userScrolled = false
        this.isAtBottom = true
      } else if (!this.userScrolled) {
        // User initiated scroll away from bottom
        this.userScrolled = true
        this.isAtBottom = false
      }
    })

    // Auto-scroll on content changes (streaming)
    this.observer = new MutationObserver(() => {
      // Only auto-scroll if user hasn't manually scrolled away
      if (!this.userScrolled || this.isAtBottom) {
        this.scrollToBottom()
      }
    })

    this.observer.observe(this.el, {
      childList: true,
      subtree: true,
      characterData: true
    })

    // Initial scroll to bottom
    this.scrollToBottom()
  },

  updated() {
    // Auto-scroll on LiveView updates if not user-scrolled
    if (!this.userScrolled || this.isAtBottom) {
      this.scrollToBottom()
    }
  },

  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
    this.isAtBottom = true
  },

  handleEvent(event, payload) {
    if (event === "scroll_to") {
      if (payload.position === "bottom") {
        // Scroll to bottom (G key)
        this.el.scrollTop = this.el.scrollHeight
        this.isAtBottom = true
        this.userScrolled = false
      } else if (payload.position === "top") {
        // Scroll to top (gg keys)
        this.el.scrollTop = 0
        this.isAtBottom = false
        this.userScrolled = true
      } else if (payload.delta !== undefined) {
        // Relative scroll (j/k/Ctrl+u/Ctrl+d)
        this.el.scrollTop += payload.delta
        // Check if we're at bottom after scroll
        const isNowAtBottom = this.el.scrollHeight - this.el.scrollTop <= this.el.clientHeight + 50
        this.isAtBottom = isNowAtBottom
        this.userScrolled = !isNowAtBottom
      }
    }
  },

  destroyed() {
    if (this.observer) {
      this.observer.disconnect()
    }
  }
}

// Input Focus Hook
// Manages input focus based on vim mode (insert vs normal)
const InputFocus = {
  mounted() {
    // Focus input on mount (default to insert mode)
    this.el.focus()
  },

  updated() {
    // Check for vim_mode changes via data attribute
    const mode = this.el.dataset.vimMode

    if (mode === "insert") {
      this.el.focus()
    } else if (mode === "normal" || mode === "command") {
      this.el.blur()
    }
  }
}

// Textarea Input Hook
// Combines focus management (vim mode) and Enter key handling (submit vs newline)
const TextareaInput = {
  mounted() {
    // Focus input on mount (default to insert mode)
    this.el.focus()

    // Handle Enter to submit, Shift+Enter for newline
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) {
        // Enter without Shift - submit the form
        e.preventDefault()
        const form = this.el.closest("form")
        if (form) {
          // Trigger native form submission (LiveView intercepts this)
          form.requestSubmit()
        }
      }
      // Shift+Enter allows default behavior (newline)
    })
  },

  updated() {
    // Check for vim_mode changes via data attribute
    const mode = this.el.dataset.vimMode

    if (mode === "insert") {
      this.el.focus()
    } else if (mode === "normal" || mode === "command") {
      this.el.blur()
    }
  }
}

// Syntax Highlighting Hook
// Applies highlight.js to code blocks after each LiveView DOM update
const SyntaxHighlight = {
  mounted() {
    this.highlight()
  },

  updated() {
    this.highlight()
  },

  highlight() {
    // Find all code blocks within this container that haven't been highlighted
    const codeBlocks = this.el.querySelectorAll('pre code:not(.hljs)')
    codeBlocks.forEach((block) => {
      window.hljs.highlightElement(block)
    })
  }
}

// StreamingMarkdown Hook
// Renders markdown to HTML client-side during streaming to avoid LiveView DOM patching issues
const StreamingMarkdown = {
  mounted() {
    this.contentEl = this.el.querySelector('.streaming-markdown-content')
    this.handleEvent("streaming_markdown", ({ html }) => {
      if (this.contentEl) {
        this.contentEl.innerHTML = html
      }
    })
  }
}

// OpenSession Hook
// Opens a session in a new browser tab when the server pushes an "open_session" event
const OpenSession = {
  mounted() {
    this.handleEvent("open_session", ({ url }) => {
      window.open(url, "_blank")
    })
  }
}

// Initialize LiveSocket when DOM is ready
document.addEventListener("DOMContentLoaded", () => {
  // Get CSRF token from meta tag
  const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")

  // Create LiveSocket with hooks
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
  })

  // Connect to LiveView
  liveSocket.connect()

  // Expose for debugging in dev
  window.liveSocket = liveSocket
})
