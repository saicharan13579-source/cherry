import UIKit
import WebKit
import UserNotifications

/// Hosts the Cherry page and gives it the same `window.CherryApp` bridge the Android app has.
class WebViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    var web: WKWebView!
    let health = HealthReader()
    var darkBars = false
    var reminders: [Int: (Date, String, String)] = [:]
    var reminderTimer: Timer?

    override var preferredStatusBarStyle: UIStatusBarStyle { darkBars ? .lightContent : .darkContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        let dark = traitCollection.userInterfaceStyle == .dark
        let bg = dark ? UIColor(red: 0x16/255, green: 0x14/255, blue: 0x12/255, alpha: 1) : UIColor(red: 0xF4/255, green: 0xEE/255, blue: 0xE4/255, alpha: 1)
        view.backgroundColor = bg

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let ucc = WKUserContentController()
        ucc.add(self, name: "cherry")
        ucc.addUserScript(WKUserScript(source: Self.shim(fontScale: Self.fontScale(), granted: health.grantedList()),
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController = ucc
        cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        web = WKWebView(frame: view.bounds, configuration: cfg)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.isOpaque = false
        web.backgroundColor = bg
        web.scrollView.backgroundColor = bg
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.allowsBackForwardNavigationGestures = false
        web.navigationDelegate = self
        web.uiDelegate = self
        view.addSubview(web)
        load()
        Updater.check { [weak self] build in
            self?.js("window.__cherryUpdate&&window.__cherryUpdate(\(build))")
        }
        NotificationCenter.default.addObserver(self, selector: #selector(resumed), name: UIApplication.didBecomeActiveNotification, object: nil)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func load() {
        let (file, dir) = Updater.startFile()
        web.loadFileURL(file, allowingReadAccessTo: dir)
    }

    @objc func resumed() { js("window.__cherryResume&&window.__cherryResume()") }

    func js(_ code: String) {
        DispatchQueue.main.async { self.web?.evaluateJavaScript(code, completionHandler: nil) }
    }

    static func fontScale() -> Double {
        let base = UIFont.preferredFont(forTextStyle: .body).pointSize
        return Double(base / 17.0)
    }

    /// JavaScript that recreates the Android bridge on top of WebKit messages.
    static func shim(fontScale: Double, granted: String) -> String {
        return """
        (function(){
          window.__cherryApp=true;window.__cherryAPK=true;window.__cherryIOS=true;
          var post=function(m){try{window.webkit.messageHandlers.cherry.postMessage(m)}catch(e){}};
          var st={granted:\(jsonString(granted)),fs:\(fontScale)};
          window.__iosSetGranted=function(g){st.granted=g||''};
          window.CherryApp={
            version:function(){return 1},pageBuild:function(){return 0},updateStatus:function(){return ''},
            fontScale:function(){return st.fs},
            setBars:function(d){post({a:'bars',dark:!!d})},
            share:function(t){post({a:'share',text:String(t)})},
            sched:function(id,at,t,x){post({a:'sched',id:id,at:Number(at),t:String(t||''),x:String(x||'')})},
            sched2:function(id,at,t,x){post({a:'sched',id:id,at:Number(at),t:String(t||''),x:String(x||'')})},
            cancel:function(id){post({a:'cancel',id:id})},
            reload:function(){post({a:'reload'})},checkUpdate:function(){post({a:'update'})},exitApp:function(){},
            hcSupported:function(){return true},
            hcGranted:function(){return st.granted},
            hcAsk:function(){post({a:'hcAsk'})},
            hcOpen:function(){post({a:'hcOpen'});return true},
            hcRead:function(d){post({a:'hcRead',days:Number(d)||14})}
          };
        })();
        """
    }

    static func jsonString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    // MARK: messages from the page
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let a = m["a"] as? String else { return }
        switch a {
        case "bars":
            darkBars = (m["dark"] as? Bool) ?? false
            let c = darkBars ? UIColor(red: 0x16/255, green: 0x14/255, blue: 0x12/255, alpha: 1) : UIColor(red: 0xF4/255, green: 0xEE/255, blue: 0xE4/255, alpha: 1)
            view.backgroundColor = c; web.backgroundColor = c; web.scrollView.backgroundColor = c
            setNeedsStatusBarAppearanceUpdate()
        case "share":
            let text = (m["text"] as? String) ?? ""
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("cherry-backup.json")
            try? text.data(using: .utf8)?.write(to: url)
            let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            vc.popoverPresentationController?.sourceView = view
            vc.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 80, width: 1, height: 1)
            present(vc, animated: true)
        case "sched":
            let id = (m["id"] as? NSNumber)?.intValue ?? 0
            let at = (m["at"] as? NSNumber)?.doubleValue ?? 0
            reminders[id] = (Date(timeIntervalSince1970: at / 1000), (m["t"] as? String) ?? "", (m["x"] as? String) ?? "")
            syncRemindersSoon()
        case "cancel":
            let id = (m["id"] as? NSNumber)?.intValue ?? 0
            reminders.removeValue(forKey: id)
            syncRemindersSoon()
        case "reload":
            load()
        case "update":
            Updater.check { [weak self] b in self?.js("window.__cherryUpdate&&window.__cherryUpdate(\(b))") }
        case "hcAsk":
            health.requestAccess { [weak self] granted in
                guard let self = self else { return }
                self.js("window.__iosSetGranted&&window.__iosSetGranted(\(Self.jsonString(granted)));window.__hcPerm&&window.__hcPerm(\(Self.jsonString(granted)))")
            }
        case "hcOpen":
            if let u = URL(string: "x-apple-health://") { UIApplication.shared.open(u) }
        case "hcRead":
            let days = (m["days"] as? NSNumber)?.intValue ?? 14
            health.read(days: max(1, min(60, days))) { [weak self] json in
                self?.js("window.__hcData&&window.__hcData(\(json))")
            }
        default: break
        }
    }

    /// iOS keeps at most 64 pending notifications, so schedule the soonest 60.
    func syncRemindersSoon() {
        reminderTimer?.invalidate()
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in self?.syncReminders() }
    }

    func syncReminders() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        let now = Date()
        let upcoming = reminders.filter { $0.value.0 > now }.sorted { $0.value.0 < $1.value.0 }.prefix(60)
        for (id, r) in upcoming {
            let c = UNMutableNotificationContent()
            c.title = r.1
            c.body = r.2
            c.sound = .default
            let secs = max(1, r.0.timeIntervalSince(now))
            let trig = UNTimeIntervalNotificationTrigger(timeInterval: secs, repeats: false)
            center.add(UNNotificationRequest(identifier: "cherry-\(id)", content: c, trigger: trig), withCompletionHandler: nil)
        }
    }

    // MARK: links open in Safari, everything else stays in the app
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = navigationAction.request.url, let s = u.scheme?.lowercased(), s != "file", s != "about", s != "data", s != "blob" {
            UIApplication.shared.open(u)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = navigationAction.request.url { UIApplication.shared.open(u) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { load() }
}
