/*
Copyright 2020 NetFoundry, Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
import Foundation

/**
 * URLProtocol` that intercepts `http` and `https` URL requests and routes them over the `Ziti` overlay as configured in your `Ziti` controller.
 *
 * Call the `ZitiUrlProtocol.start()`method to register this `URLProtocol` and start the background processing thread for `Ziti` requests.
 */
@objc public class ZitiUrlProtocol: URLProtocol, ZitiUnretained {
    private static let log = ZitiLog(ZitiUrlProtocol.self)
    private let log = ZitiUrlProtocol.log
    
    static weak var ziti:Ziti?
    
    var started = false
    var stopped = false
    var finished = false
    
    var req:UnsafeMutablePointer<um_http_req_t>? = nil
    var resp:HTTPURLResponse?
    
    var clientThread:Thread? // Thread that calls start/stopLoading, handles client notifications
    var modes:[String] = []
    
    // hold  unretained reference to self used for uv callbacks until we're sure we're done...
    static var reqs:[ZitiUrlProtocol] = []
    
    static let tunCfgType = "ziti-tunneler-client.v1".cString(using: .utf8)!
    static let urlCfgType = "ziti-url-client.v1".cString(using: .utf8)!
    
    static var interceptsLock = NSLock()
    static var intercepts:[String:ZitiIntercept] = [:]
        
    // MARK: - Register and Service Updates
    /**
     Registers this protocol via `URLProtocol.registerClass` and subscribes for service intercept updates from `Ziti`.
     
     This metod should be called during the `InitCallback` of  `Ziti` `run(_:)`  to ensure `Ziti` is initialized before
     starting to intercept services.
     
     Note that in some cases `ZitiUrlProtocol` will need to be configured in your `URLSession`'s configuration ala:
     
      ```
      let configuration = URLSessionConfiguration.default
      configuration.protocolClasses?.insert(ZitiUrlProtocol.self, at: 0)
      urlSession = URLSession(configuration:configuration)
      ```
     
        - Parameters:
            - ziti: The `Ziti` instance we are using to route intercepted URL traffic
            - idleTime: Time, in miliiseconds,  client attempts to keep-alive an idle connection before allowing it to close. Default=10000
     */
    @objc public class func register(_ ziti:Ziti, _ idleTime:Int=10000) {
        
        // Save a weak reference to ziti that can be used by instances of ZitiUrlProtocol
        ZitiUrlProtocol.ziti = ziti
        
        // Register protocol only after ziti is running
        ziti.perform {
            URLProtocol.registerClass(ZitiUrlProtocol.self)
            log.info("ZitiUrlProtocol registered", function:"register()")
        }
        
        // Register service changed callback
        ziti.registerServiceCallback { [weak ziti] zs, status in
            onService(ziti, zs, status, idleTime)
        }
    }
    
    class func onService(_ ziti:Ziti?, _ zs:UnsafeMutablePointer<ziti_service>?, _ status:Int32, _ idleTime:Int) {
        guard let ziti = ziti, var zs = zs?.pointee else {
            log.wtf("unable to access ziti and/or service, status: \(status)", function:"onService()")
            return
        }
        
        let svcName = String(cString: zs.name)
        if status == ZITI_SERVICE_UNAVAILABLE {
            interceptsLock.lock()
            intercepts = intercepts.filter { $0.value.name !=  svcName }
            interceptsLock.unlock()
        } else if status == ZITI_OK {
            
            // prefer urlCfgType, tunCfgType as fallback
            var foundUrlCfg = false
            if let cfg = ZitiIntercept.parseConfig(ZitiUrlConfig.self, &zs) {
                let urlStr = "\(cfg.scheme)://\(cfg.hostname):\(cfg.getPort())"
                
                interceptsLock.lock()
                if let curr = ZitiUrlProtocol.intercepts[urlStr] {
                    log.info("intercept \"\(urlStr)\" changing from \"\(curr.name)\" to \"\(svcName)\"", function:"onService()")
                    curr.close()
                }
                let intercept = ZitiIntercept(ziti, svcName, urlStr, idleTime)
                intercept.hdrs = cfg.headers ?? [:]
                intercepts[intercept.urlStr] = intercept
                
                log.info("Setting URL intercept svc \(svcName): \(urlStr)")
                interceptsLock.unlock()
                
                foundUrlCfg = true
            }
            
            // fallback to tun config type
            if !foundUrlCfg, let cfg = ZitiIntercept.parseConfig(ZitiTunnelConfig.self, &zs) {
                let hostPort = "\(cfg.hostname):\(cfg.port)"
                   
                interceptsLock.lock()
                
                if let curr = ZitiUrlProtocol.intercepts["http://\(hostPort)"] {
                    log.info("intercept \"http://\(hostPort)\" changing from \"\(curr.name)\" to \"\(svcName)\"", function:"onService()")
                    curr.close()
                }
                if let curr = ZitiUrlProtocol.intercepts["https://\(hostPort)"] {
                    log.info("intercept \"https://\(hostPort)\" changing from \"\(curr.name)\" to \"\(svcName)\"", function:"onService()")
                    curr.close()
                }
                
                if let scheme = (cfg.port == 80 ? "http" : (cfg.port == 443 ? "https" : nil)) {
                    let intercept = ZitiIntercept(ziti, svcName, "\(scheme)://\(hostPort)", idleTime)
                    intercepts[intercept.urlStr] = intercept
                    log.info("Setting TUN intercept svc \(scheme)://\(hostPort): \(hostPort)", function:"onService()()")
                } else {
                    var intercept = ZitiIntercept(ziti, svcName, "http://\(hostPort)", idleTime)
                    intercepts[intercept.urlStr] = intercept
                    intercept = ZitiIntercept(ziti, svcName, "https://\(hostPort)", idleTime)
                    intercepts[intercept.urlStr] = intercept
                    log.info("Setting TUN intercept svc \(svcName): \(hostPort)", function:"onService()()")
                }
                interceptsLock.unlock()
            }
        }
    }
    
    //
    // MARK: - URLProtocol
    //
    override init(request: URLRequest, cachedResponse: CachedURLResponse?, client: URLProtocolClient?) {
        super.init(request: request, cachedResponse: cachedResponse, client: client)
        log.debug("init \(self), Thread: \(String(describing: Thread.current.name))")
    }
    
    deinit {
        log.debug("deinit \(self), Thread: \(String(describing: Thread.current.name))")
    }
    
    public override class func canInit(with request: URLRequest) -> Bool {
        var canIntercept = false;
        if let url = request.url, let scheme = url.scheme, let host = url.host {
            var port = url.port
            if port == nil { port = (scheme == "https") ? 443 : 80 }
            let key = "\(scheme)://\(host):\(port!)"
            
            ZitiUrlProtocol.interceptsLock.lock()
            if ZitiUrlProtocol.intercepts[key] != nil {
                canIntercept = true
            }
            ZitiUrlProtocol.interceptsLock.unlock()
        }
        log.info("*-*-*-*-* is\(canIntercept ? "" : " NOT") intercepting \(request.debugDescription)")
        return canIntercept
    }
    
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    public override func startLoading() {
        guard let ziti = ZitiUrlProtocol.ziti else {
            log.wtf("Invalid ziti reference")
            return
        }
        
        // client callbacks need to run in client thread in any of its modes
        clientThread = Thread.current
        modes.append(RunLoop.Mode.default.rawValue)
        let cm = RunLoop.current.currentMode?.rawValue
        if cm != nil && cm! != RunLoop.Mode.default.rawValue {
            modes.append(cm!)
        }
        
        // queue the request for processing on the uv_loop
        ziti.perform {
            // save a reference to self to prevent zitiUnretained WTFs on callbacks from C-SDK
            ZitiUrlProtocol.reqs.append(self)
            
            self.started = true
            let urlStr = self.getUrlString()
            
            ZitiUrlProtocol.interceptsLock.lock()
            if let intercept = ZitiUrlProtocol.intercepts[urlStr] {
                self.req = intercept.createRequest(self, self.getUrlPath(),
                                                  ZitiUrlProtocol.on_http_resp,
                                                  ZitiUrlProtocol.on_http_body,
                                                  self.toVoidPtr())
            }
            ZitiUrlProtocol.interceptsLock.unlock()
        }
    }
    
    public override func stopLoading() {
        guard let ziti = ZitiUrlProtocol.ziti else {
            log.wtf("Invalid ziti reference")
            return
        }
        ziti.perform {
            // We don't want to call um_http_close since we would rather just keep
            // using the um_http_t (e.g., for the next startLoading() for this server, especially
            // when http keep-alive is > 0). Also, there's no close callback on um_http_close,
            // so even then might be tough to know...
            //
            // Removing the ZitiUrlProtol from the reqs array here could cause an issue where
            // we keep getting callbacks from um_http after the ZitiUrlProtocol instance has
            // been released.
            //
            // So, we'll synchronize releasing the ZitiUrlProtocol only after stopLoading() *and*
            // on_http_body() indicates we won't get any more um_http callback.
            ZitiUrlProtocol.reqs.forEach { zup in
                if zup.started { zup.stopped = true }
            }
            ZitiUrlProtocol.reqs = ZitiUrlProtocol.reqs.filter { !($0.stopped && $0.finished) }
        }
    }
        
    //
    // MARK: - um_http callbacks
    //
    static private let on_http_resp:um_http_resp_cb = { resp, ctx in
        guard let resp = resp, let mySelf = zitiUnretained(ZitiUrlProtocol.self, ctx) else {
            log.wtf("unable to decode context")
            return
        }
        guard let reqUrl = mySelf.request.url else {
            log.wtf("unable to determine request URL")
            return
        }
        
        var hdrMap:[String:String] = [:]
        for i in 0..<resp.pointee.nh {
            let hdr = resp.pointee.headers[Int(i)]
            hdrMap[String(cString: hdr.name)] = String(cString: hdr.value)
        }
                        
        // On TLS handshake error getting a negative response code (-53), notifyDidReceive
        // nothing, so we end up waiting for timeout. So notifyDidFailWithError instead...
        let code = Int(resp.pointee.code)
        guard code > 0 else {
            let str = String(cString: uv_strerror(Int32(code)))
            log.error(str)
            let err = ZitiError(str, errorCode: code)
            mySelf.notifyDidFailWithError(ZitiError(str, errorCode: code))
            return
        }
        
        // attempt to follow re-directs
        var wasRedirected = false
        if code >= 300 && code <= 308 && code != 304 && code != 305 {
            if let location = hdrMap["Location"] {
                if let url = URL(string: location, relativeTo: mySelf.request.url) {
                    var newRequest = URLRequest(url: url)
                    newRequest.httpMethod = (code == 303 ? "GET" : mySelf.request.httpMethod)
                    newRequest.allHTTPHeaderFields = mySelf.request.allHTTPHeaderFields
                    newRequest.httpBody = mySelf.request.httpBody
                    
                    if var origResp = HTTPURLResponse(
                        url: url,
                        statusCode: Int(resp.pointee.code),
                        httpVersion: nil,
                        headerFields: hdrMap) {
                        
                        wasRedirected = true
                        mySelf.notifyWasRedirectedTo(newRequest, origResp)
                    }
                }
            }
        }
        
        if !wasRedirected {
            mySelf.resp = HTTPURLResponse(url: reqUrl,
                                          statusCode: code,
                                          httpVersion: nil, // "HTTP/" + String(cString: resp.pointee.http_version)
                                          headerFields: hdrMap)
            guard let httpResp = mySelf.resp else {
                log.error("unable create response object for \(reqUrl)")
                return
            }
            mySelf.notifyDidReceive(httpResp)
        }
    }
    
    static private let on_http_body:um_http_body_cb = { req, body, len in
        guard let req = req, let mySelf = zitiUnretained(ZitiUrlProtocol.self ,req.pointee.data) else {
            log.wtf("unable to decode context")
            return
        }
        
        if uv_errno_t(Int32(len)) == UV_EOF {
            mySelf.notifyDidFinishLoading()
            mySelf.finished = true
        } else if len < 0 {
            let str = String(cString: uv_strerror(Int32(len)))
            let err = ZitiError(str, errorCode: len)
            mySelf.notifyDidFailWithError(err)
        } else {
            let data = Data(bytes: body!, count: len)
            mySelf.notifyDidLoad(data)
            mySelf.finished = true
        }
        
        // Filter out all that are stopped and finished
        // see also stopLoading()
        ZitiUrlProtocol.reqs = ZitiUrlProtocol.reqs.filter { !($0.stopped && $0.finished) }
    }
    
    //
    // MARK: - Client Notifications
    // Methods for forcing the client callbacks to run on the client thread
    // when called from uv_loop callbacks
    //
    @objc private func notifyDidFinishLoadingSelector(_ arg:Any?) {
        client?.urlProtocolDidFinishLoading(self)
    }
    private func notifyDidFinishLoading() {
        performOnClientThread(#selector(notifyDidFinishLoadingSelector), nil)
    }
    
    @objc private func notifyDidFailWithErrorSelector(_ err:Error) {
        client?.urlProtocol(self, didFailWithError: err)
    }
    private func notifyDidFailWithError(_ error:Error) {
        performOnClientThread(#selector(notifyDidFailWithErrorSelector), error)
    }
    
    @objc private func notifyDidLoadSelector(_ data:Data) {
        client?.urlProtocol(self, didLoad: data)
    }
    private func notifyDidLoad(_ data:Data) {
        performOnClientThread(#selector(notifyDidLoadSelector), data)
    }
    
    @objc private func notifyDidReceiveSelector(_ resp:HTTPURLResponse) {
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
    }
    private func notifyDidReceive(_ resp:HTTPURLResponse) {
        performOnClientThread(#selector(notifyDidReceiveSelector), resp)
    }
    
    @objc private func notifyWasRedirectedToSelector(_ arg:[Any]) {
        guard let req = arg[0] as? URLRequest, let resp = arg[1] as? URLResponse else { return }
        client?.urlProtocol(self, wasRedirectedTo: req, redirectResponse: resp)
    }
    private func notifyWasRedirectedTo(_ req:URLRequest, _ resp:URLResponse) {
        performOnClientThread(#selector(notifyWasRedirectedToSelector), [req, resp])
    }
    
    private func performOnClientThread(_ aSelector:Selector, _ arg:Any?) {
        perform(aSelector, on: clientThread!, with:arg, waitUntilDone:false, modes:modes)
    }

    //
    // MARK: - Helpers
    // Helpers for manipulating URL to map to um_http calls
    //
    private func getUrlString() -> String {
        guard let url = request.url, let scheme = url.scheme, let host = url.host else {
            return ""
        }
        var port = url.port
        if port == nil { port = (scheme == "https") ? 443 : 80 }
        return "\(scheme)://\(host):\(port!)"
    }
    private func getUrlPath() -> String {
        guard let url = request.url else { return "/" }
        guard url.path.count > 0 else { return "/" }
        return url.query == nil ? url.path : "\(url.path)?\(url.query!)"
    }
}
