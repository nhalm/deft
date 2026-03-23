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
          // Trigger form submit event
          form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))
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
      TextareaInput
    }
  })

  // Connect to LiveView
  liveSocket.connect()

  // Expose for debugging in dev
  window.liveSocket = liveSocket
})
