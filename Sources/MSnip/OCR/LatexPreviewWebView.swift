import AppKit
import Foundation
import MSnipCore
import WebKit

/// 基于 Apple 原生 `WKWebView` 的实时 LaTeX 数学公式渲染预览视图（在线自动启用 KaTeX 精排，离线优雅降级等宽展示）
final class LatexPreviewWebView: NSView, WKNavigationDelegate {
    private var webView: WKWebView?
    private var isPageLoaded = false
    private var pendingLatex: String = ""
    private var isDarkMode = false

    override init(frame frameRect: NSRect) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        self.webView = wv
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = MSnipUITheme.cardSolid.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = MSnipUITheme.borderHairline.cgColor
        layer?.masksToBounds = true

        wv.setValue(false, forKey: "drawsBackground")
        wv.navigationDelegate = self
        wv.autoresizingMask = [.width, .height]
        wv.frame = bounds
        addSubview(wv)
        wv.loadHTMLString(Self.shellHTML, baseURL: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isPageLoaded = true
        setDarkMode(isDarkMode)
        render(latex: pendingLatex)
    }

    func setDarkMode(_ dark: Bool) {
        isDarkMode = dark
        layer?.backgroundColor = ResultTheme.cgColor(ResultTheme.cardSolid, dark: dark)
        layer?.borderColor = ResultTheme.cgColor(ResultTheme.borderHairline, dark: dark)
        if isPageLoaded { webView?.evaluateJavaScript("document.documentElement.dataset.theme='\(dark ? "dark" : "light")';", completionHandler: nil) }
    }

    /// 彻底销毁 WKWebView 渲染内容并断开代理，触发系统立即回收 WebKit XPC 子进程
    func teardown() {
        isPageLoaded = false
        pendingLatex = ""
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.loadHTMLString("", baseURL: nil)
        webView?.removeFromSuperview()
        webView = nil
    }

    func render(latex: String) {
        pendingLatex = latex
        guard isPageLoaded, let webView else { return }
        let clean = LatexPostProcessor.stripFencesAndDelimiters(latex)
        guard let jsonData = try? JSONSerialization.data(withJSONObject: [clean]),
              let arrStr = String(data: jsonData, encoding: .utf8),
              arrStr.count >= 2 else { return }
        let jsLiteral = String(arrStr.dropFirst().dropLast())
        webView.evaluateJavaScript("window.renderMSnipLatex(\(jsLiteral));", completionHandler: nil)
    }

    private static let shellHTML = """
    <!doctype html><html><head><meta charset="utf-8">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
    <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js" onload="window._kReady=true;if(window._last!==undefined)window.renderMSnipLatex(window._last);"></script>
    <style>
      *{box-sizing:border-box;margin:0;padding:0}
      html,body{width:100%;height:100%;background:transparent;font-family:-apple-system,BlinkMacSystemFont,sans-serif;overflow:auto;}
      #wrap{min-height:100%;display:flex;align-items:center;justify-content:center;padding:12px 16px;color:#141923;}
      .katex-display{margin:0 !important;}
      .katex{font-size:1.32em;}
      .fallback{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:13px;color:#3b4455;white-space:pre-wrap;word-break:break-word;text-align:center;}
      .empty{font-size:12px;color:#798395;}
      html[data-theme="dark"] #wrap{color:#eef2f7;}
      html[data-theme="dark"] .fallback{color:#cbd5e1;}
      html[data-theme="dark"] .empty{color:#8b95a5;}
    </style></head><body><div id="wrap"><span class="empty">公式渲染预览</span></div>
    <script>
      window.renderMSnipLatex = function(tex){
        window._last = tex;
        var el = document.getElementById('wrap');
        if(!tex || !tex.trim()){ el.innerHTML = '<span class="empty">公式渲染预览</span>'; return; }
        if(window.katex){
          try{
            el.innerHTML = window.katex.renderToString(tex, {displayMode:true, throwOnError:false, strict:false});
            return;
          }catch(e){}
        }
        el.innerHTML = '';
        var span = document.createElement('div');
        span.className = 'fallback';
        span.textContent = tex;
        el.appendChild(span);
      };
    </script></body></html>
    """
}
