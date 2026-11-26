import AppKit
import Foundation
import MSnipCore
import WebKit

/// 基于 Apple 原生 `WKWebView` 的实时 LaTeX 数学公式预览视图：
/// - 离线零等待直出 macOS WebKit 原生 C++ MathML 排版（支持分式、根号、上下标、积分求和、矩阵/方程组、希腊字母）；
/// - 在线环境下自动渐进增强为 KaTeX 出版级精排。
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

    private static let shellHTML = #"""
    <!doctype html><html><head><meta charset="utf-8">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
    <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js" onload="if(window._last!==undefined)window.renderMSnipLatex(window._last);"></script>
    <style>
      *{box-sizing:border-box;margin:0;padding:0}
      html,body{width:100%;height:100%;background:transparent;font-family:-apple-system,BlinkMacSystemFont,sans-serif;overflow:auto;}
      #wrap{min-height:100%;display:flex;align-items:center;justify-content:center;padding:12px 16px;color:#141923;}
      .katex-display{margin:0 !important;}
      .katex,math{font-size:1.36em;}
      .empty{font-size:12px;color:#798395;}
      html[data-theme="dark"] #wrap{color:#eef2f7;}
      html[data-theme="dark"] .empty{color:#8b95a5;}
    </style></head><body><div id="wrap"><span class="empty">公式渲染预览</span></div>
    <script>
      (function(){
        const SYM={alpha:'α',beta:'β',gamma:'γ',delta:'δ',epsilon:'ϵ',varepsilon:'ε',zeta:'ζ',eta:'η',theta:'θ',vartheta:'ϑ',iota:'ι',kappa:'κ',lambda:'λ',mu:'μ',nu:'ν',xi:'ξ',pi:'π',rho:'ρ',sigma:'σ',tau:'τ',upsilon:'υ',phi:'ϕ',varphi:'φ',chi:'χ',psi:'ψ',omega:'ω',Gamma:'Γ',Delta:'Δ',Theta:'Θ',Lambda:'Λ',Xi:'Ξ',Pi:'Π',Sigma:'Σ',Upsilon:'Υ',Phi:'Φ',Psi:'Ψ',Omega:'Ω',infty:'∞',partial:'∂',nabla:'∇',pm:'±',mp:'∓',times:'×',div:'÷',cdot:'⋅',cdots:'⋯',ldots:'…',dots:'…',vdots:'⋮',ddots:'⋱',leq:'≤',le:'≤',geq:'≥',ge:'≥',neq:'≠',ne:'≠',approx:'≈',equiv:'≡',sim:'∼',simeq:'≃',propto:'∝',in:'∈',notin:'∉',subset:'⊂',subseteq:'⊆',supset:'⊃',supseteq:'⊇',cup:'∪',cap:'∩',emptyset:'∅',forall:'∀',exists:'∃',neg:'¬',land:'∧',lor:'∨',to:'→',rightarrow:'→',leftarrow:'←',leftrightarrow:'↔',Rightarrow:'⇒',Leftarrow:'⇐',Leftrightarrow:'⇔',mapsto:'↦',sum:'∑',prod:'∏',coprod:'∐',int:'∫',iint:'∬',iiint:'∭',oint:'∮',prime:'′',angle:'∠',perp:'⊥',parallel:'∥',triangle:'△',star:'⋆',circ:'∘',bullet:'∙',oplus:'⊕',otimes:'⊗'};
        const BIG=new Set(['sum','prod','coprod','lim','sup','inf','max','min']);
        const FN=new Set(['sin','cos','tan','cot','sec','csc','arcsin','arccos','arctan','sinh','cosh','tanh','ln','log','exp','lim','max','min','sup','inf','det','gcd','deg','dim','ker','arg','mod']);
        const ACC={hat:'^',widehat:'^',bar:'¯',overline:'¯',vec:'→',overrightarrow:'→',tilde:'~',widetilde:'~',dot:'˙',ddot:'¨'};
        function esc(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
        function texToMathML(src){
          let i=0,n=src.length;
          function skip(){while(i<n&&/\s/.test(src[i]))i++;}
          function grp(){
            skip();if(i>=n)return '<mrow></mrow>';
            if(src[i]==='{'){i++;let r=seq('}');if(src[i]==='}')i++;return '<mrow>'+r+'</mrow>';}
            return atom(false);
          }
          function brk(){
            skip();if(src[i]!=='[')return null;i++;let s='';
            while(i<n&&src[i]!==']')s+=src[i++];if(src[i]===']')i++;
            return '<mrow>'+texInner(s)+'</mrow>';
          }
          function env(name){
            const tag='\\end{'+name+'}',idx=src.indexOf(tag,i);
            const body=idx>=0?src.slice(i,idx):src.slice(i);
            i=idx>=0?idx+tag.length:n;
            const rows=body.split(/\\\\/).filter(r=>r.trim().length>0).map(r=>'<mtr>'+r.split('&').map(c=>'<mtd>'+texInner(c)+'</mtd>').join('')+'</mtr>').join('');
            const tbl='<mtable>'+rows+'</mtable>';
            if(name==='pmatrix')return '<mrow><mo>(</mo>'+tbl+'<mo>)</mo></mrow>';
            if(name==='bmatrix')return '<mrow><mo>[</mo>'+tbl+'<mo>]</mo></mrow>';
            if(name==='vmatrix')return '<mrow><mo>|</mo>'+tbl+'<mo>|</mo></mrow>';
            if(name==='cases')return '<mrow><mo>{</mo>'+tbl+'</mrow>';
            return tbl;
          }
          function atom(withScripts){
            skip();if(i>=n)return '';
            let base='',isBig=false,c=src[i];
            if(c==='{'){base=grp();}
            else if(c==='\\'){
              i++;if(i>=n)return '';
              if(!/[a-zA-Z]/.test(src[i])){
                const ch=src[i++];
                base=(ch===' '||ch===','||ch===';'||ch===':')?'<mspace width="0.22em"/>':(ch==='{'||ch==='}'||ch==='|')?'<mo>'+esc(ch)+'</mo>':'<mtext>'+esc(ch)+'</mtext>';
              }else{
                let cmd='';while(i<n&&/[a-zA-Z]/.test(src[i]))cmd+=src[i++];
                if(cmd==='left'||cmd==='right'){skip();let d=i<n?src[i++]:'';if(d==='\\'&&i<n)d=src[i++];base=(d==='.')?'':'<mo stretchy="true">'+esc(d)+'</mo>';}
                else if(cmd==='frac'||cmd==='dfrac'||cmd==='tfrac'){let a=grp(),b=grp();base='<mfrac>'+a+b+'</mfrac>';}
                else if(cmd==='binom'){let a=grp(),b=grp();base='<mrow><mo>(</mo><mfrac linethickness="0">'+a+b+'</mfrac><mo>)</mo></mrow>';}
                else if(cmd==='sqrt'){let deg=brk(),rad=grp();base=deg?'<mroot>'+rad+deg+'</mroot>':'<msqrt>'+rad+'</msqrt>';}
                else if(cmd==='text'||cmd==='mathrm'||cmd==='operatorname'){skip();if(src[i]==='{'){i++;let t='';while(i<n&&src[i]!=='}')t+=src[i++];if(src[i]==='}')i++;base='<mtext>'+esc(t)+'</mtext>';}else base=grp();}
                else if(cmd==='mathbf'||cmd==='boldsymbol'||cmd==='mathbb'||cmd==='mathcal'){base='<mstyle mathvariant="'+(cmd==='mathbb'?'double-struck':cmd==='mathcal'?'script':'bold')+'">'+grp()+'</mstyle>';}
                else if(cmd==='begin'){skip();let en='';if(src[i]==='{'){i++;while(i<n&&src[i]!=='}')en+=src[i++];if(src[i]==='}')i++;}base=env(en);}
                else if(ACC[cmd]){base='<mover accent="true">'+grp()+'<mo>'+ACC[cmd]+'</mo></mover>';}
                else if(FN.has(cmd)){isBig=BIG.has(cmd);base='<mo movablelimits="false">'+cmd+'</mo>';}
                else if(SYM[cmd]){isBig=BIG.has(cmd);const v=SYM[cmd];base=/[α-ωΑ-Ω∂∇∞]/.test(v)?'<mi>'+v+'</mi>':'<mo>'+v+'</mo>';}
                else base='<mi>'+esc(cmd)+'</mi>';
              }
            }else if(/[0-9]/.test(c)){
              let num='';while(i<n&&/[0-9.]/.test(src[i]))num+=src[i++];base='<mn>'+num+'</mn>';
            }else if(/[a-zA-Z]/.test(c)){
              i++;base='<mi>'+c+'</mi>';
            }else{
              i++;base='<mo>'+esc(c)+'</mo>';
            }
            if(!withScripts)return base;
            let sub=null,sup=null;
            for(let k=0;k<2;k++){
              skip();
              if(src[i]==='_'&&!sub){i++;sub=grp();}
              else if(src[i]==='^'&&!sup){i++;sup=grp();}
              else if(src[i]==="'"&&!sup){let p='';while(src[i]==="'"){p+='′';i++;}sup='<mo>'+p+'</mo>';}
            }
            if(sub&&sup)return isBig?'<munderover>'+base+sub+sup+'</munderover>':'<msubsup>'+base+sub+sup+'</msubsup>';
            if(sub)return isBig?'<munder>'+base+sub+'</munder>':'<msub>'+base+sub+'</msub>';
            if(sup)return isBig?'<mover>'+base+sup+'</mover>':'<msup>'+base+sup+'</msup>';
            return base;
          }
          function seq(stop){
            let out='';
            while(i<n){skip();if(i>=n||(stop&&src[i]===stop))break;out+=atom(true);}
            return out;
          }
          return seq(null);
        }
        function texInner(s){return texToMathML(s);}
        window.renderMSnipLatex=function(tex){
          window._last=tex;
          const el=document.getElementById('wrap');
          if(!tex||!tex.trim()){el.innerHTML='<span class="empty">公式渲染预览</span>';return;}
          if(window.katex){
            try{el.innerHTML=window.katex.renderToString(tex,{displayMode:true,throwOnError:false,strict:false});return;}catch(e){}
          }
          try{
            el.innerHTML='<math xmlns="http://www.w3.org/1998/Math/MathML" display="block"><mrow>'+texToMathML(tex)+'</mrow></math>';
          }catch(e){
            el.textContent=tex;
          }
        };
      })();
    </script></body></html>
    """#
}
