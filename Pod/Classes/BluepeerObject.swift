//
//  BluepeerObject.swift
//  Photobooth
//
//  Created by Tim Carr on 7/7/16.
//  Copyright © 2016 Tim Carr Photo. All rights reserved.
//

import Foundation
import CoreBluetooth
import CFNetwork
import CocoaAsyncSocket
import HHServices

// NOTE: requires pod CocoaAsyncSocket

@objc public enum RoleType: Int, CustomStringConvertible {
    case Unknown = 0
    case Server = 1
    case Client = 2
    case All = 3
    
    public var description: String {
        switch self {
        case .Server: return "Server"
        case .Client: return "Client"
        case .Unknown: return "Unknown"
        case .All: return "All"
        }
    }
    
    public static func roleFromString(roleStr: String?) -> RoleType {
        guard let roleStr = roleStr else {
            return .Unknown
        }
        switch roleStr {
            case "Server": return .Server
            case "Client": return .Client
            case "Unknown": return .Unknown
            case "All": return .All
        default: return .Unknown
        }
    }
}

@objc public enum BluetoothState: Int {
    case Unknown = 0
    case PoweredOff = 1
    case PoweredOn = 2
    case Other = 3
}


@objc public enum BPPeerState: Int, CustomStringConvertible {
    case NotConnected = 0
    case Connecting = 1
    case AwaitingAuth = 2
    case Connected = 3
    
    public var description: String {
        switch self {
        case .NotConnected: return "NotConnected"
        case .Connecting: return "Connecting"
        case .Connected: return "Connected"
        case .AwaitingAuth: return "AwaitingAuth"
        }
    }
}

@objc public class BPPeer: NSObject {
    public var displayName: String = "Unknown"
    public var socket: GCDAsyncSocket? // has IP at .userData or .connectedHost
    public var role: RoleType = .Unknown
    public var state: BPPeerState = .NotConnected
    public var IP: String = "0.0.0.0"
    override public func isEqual(object: AnyObject?) -> Bool {
        if let rhs = object as? BPPeer {
            return self.IP == rhs.IP
        } else {
            return false
        }
    }
    override public var hash: Int {
        return self.IP.hash
//        let acceptableChars = NSCharacterSet.init(charactersInString: "1234567890")
//        var str = "1" + IP
//        str = String(str.characters.filter { acceptableChars.containsCharacter($0) })
//        return Int.init(str)!
    }
}

@objc public protocol BluepeerSessionManagerDelegate {
    optional func peerDidConnect(peerRole: RoleType, peer: BPPeer)
    optional func peerDidDisconnect(peerRole: RoleType, peer: BPPeer)
    optional func peerConnectionAttemptFailed(peerRole: RoleType, peer: BPPeer, isAuthRejection: Bool)
    optional func peerConnectionRequest(peer: BPPeer, invitationHandler: (Bool) -> Void) // was named: sessionConnectionRequest
    optional func browserFoundPeer(role: RoleType, peer: BPPeer, inviteBlock: (connect: Bool, timeoutForInvite: NSTimeInterval) -> Void)
}

@objc public protocol BluepeerDataDelegate {
    func didReceiveData(data: NSData, fromPeer peerID: BPPeer)
}

@objc public class BluepeerObject: NSObject {
    
    var delegateQueue: dispatch_queue_t?
    var serverSocket: GCDAsyncSocket?
    var publisher: HHServicePublisher?
    var browser: HHServiceBrowser?
    var overBluetoothOnly: Bool = false
    public var advertising: Bool = false
    public var browsing: Bool = false
    public var serviceType: String
    var serverPort: UInt16 = 0
    var versionString: String = "unknown"
    var displayName: String = UIDevice.currentDevice().name
    weak public var sessionDelegate: BluepeerSessionManagerDelegate?
    weak public var dataDelegate: BluepeerDataDelegate?
    public var peers = Set<BPPeer>()
    var servicesBeingResolved = Set<HHService>()
    public var bluetoothState : BluetoothState = .Unknown
    var bluetoothPeripheralManager: CBPeripheralManager
    public var bluetoothBlock: ((bluetoothState: BluetoothState) -> Void)?
    public var disconnectOnWillResignActive: Bool = false {
        didSet {
            if disconnectOnWillResignActive {
                NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(willResignActive), name: UIApplicationWillResignActiveNotification, object: nil)
            } else {
                NSNotificationCenter.defaultCenter().removeObserver(self, name: UIApplicationWillResignActiveNotification, object: nil)
            }
        }
    }
    let headerTerminator: NSData = "\r\n\r\n".dataUsingEncoding(NSUTF8StringEncoding)! // same as HTTP. But header content here is just a number, representing the byte count of the incoming nsdata.
    
    enum DataTag: Int {
        case TAG_HEADER = 1
        case TAG_BODY = 2
        case TAG_WRITING = 3
        case TAG_AUTH = 4
    }
    
    // if queue isn't given, main queue is used
    public init(serviceType: String, displayName:String?, queue:dispatch_queue_t?, serverPort: UInt16, overBluetoothOnly:Bool, bluetoothBlock: ((bluetoothState: BluetoothState)->Void)?) { // serviceType must be 1-15 chars, only a-z0-9 and hyphen, eg "xd-blueprint"
        self.serverPort = serverPort
        self.serviceType = "_" + serviceType + "._tcp"
        self.overBluetoothOnly = overBluetoothOnly
        self.delegateQueue = queue
        self.bluetoothPeripheralManager = CBPeripheralManager.init(delegate: nil, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey:0])
        
        super.init()

        if let name = displayName {
            self.displayName = name
        }

        // sanitize name
        self.displayName = self.displayName.lowercaseString
        if self.displayName.characters.count > 15 {
            self.displayName = self.displayName.substringToIndex(self.displayName.startIndex.advancedBy(15))
        }
        let acceptableChars = NSCharacterSet.init(charactersInString: "abcdefghijklmnopqrstuvwxyz1234567890-")
        self.displayName = String(self.displayName.characters.map { (char: Character) in
            if acceptableChars.containsCharacter(char) == false {
                return "-"
            } else {
                return char
            }
        })
        
        if let bundleVersionString = NSBundle.mainBundle().infoDictionary?["CFBundleVersion"] as? String {
            versionString = bundleVersionString
        }

        self.bluetoothBlock = bluetoothBlock
        self.bluetoothPeripheralManager = CBPeripheralManager.init(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey:0])
        NSLog("Initialized BluepeerObject. Name: \(self.displayName), bluetoothOnly: \(overBluetoothOnly ? "yes" : "no")")
    }
    
    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self)
    }
    
    // Note: only disconnect is handled. My delegate is expected to reconnect if needed.
    func willResignActive() {
        NSLog("BluepeerObject: willResignActive, disconnecting.")
        stopBrowsing()
        stopAdvertising()
        disconnectSession()
    }
    
    public func disconnectSession() {
        // don't close serverSocket: expectation is that only stopAdvertising does this
        // loop through peers, disconenct all sockets
        for peer in self.peers {
            NSLog("BluepeerObject disconnectSession: disconnecting \(peer.IP)")
            peer.socket?.delegate = nil // we don't want to run our disconnection logic below
            peer.socket?.disconnect()
            peer.socket = nil
            peer.state = .NotConnected
        }
    }
    
    public func connectedRoleCount(role: RoleType) -> Int {
        return self.peers.filter({ $0.role == role && $0.state == .Connected }).count
    }
    
    public func startAdvertising(role: RoleType) {
        if self.advertising == true {
            NSLog("BluepeerObject: Already advertising (no-op)")
            return
        }

        NSLog("BluepeerObject: starting advertising using port %d", serverPort)

        // type must be like: _myexampleservice._tcp  (no trailing .)
        // txtData: let's use this for RoleType. For now just shove RoleType in there!
        // txtData, from http://www.zeroconf.org/rendezvous/txtrecords.html: Using TXT records larger than 1300 bytes is NOT RECOMMENDED at this time. The format of the data within a DNS TXT record is zero or more strings, packed together in memory without any intervening gaps or padding bytes for word alignment. The format of each constituent string within the DNS TXT record is a single length byte, followed by 0-255 bytes of text data.
    
        // Could use the NSNetService version of this (TXTDATA maker), it'd be easier :)
        let txtdict: CFDictionary = ["role":"Server"] // assume I am a Server if I am told to start advertising
        let cfdata: Unmanaged<CFData>? = CFNetServiceCreateTXTDataWithDictionary(kCFAllocatorDefault, txtdict)
        let txtdata = cfdata?.takeUnretainedValue()
        guard let _ = txtdata else {
            NSLog("BluepeerObject: ERROR could not create TXTDATA nsdata")
            return
        }
        self.publisher = HHServicePublisher.init(name: self.displayName, type: self.serviceType, domain: "local.", txtData: txtdata, port: UInt(serverPort), includeP2P: true)
        
        guard let publisher = self.publisher else {
            NSLog("BluepeerObject: could not create publisher")
            return
        }
        publisher.delegate = self
        let starting = publisher.beginPublishOverBluetoothOnly(self.overBluetoothOnly)
        if !starting {
            NSLog("BluepeerObject ERROR: could not start advertising")
            self.publisher = nil
        }
        // serverSocket is created in didPublish delegate (from HHServicePublisherDelegate) below
    }
    
    public func stopAdvertising() {
        if (self.advertising) {
            guard let publisher = self.publisher else {
                NSLog("BluepeerObject: publisher is MIA while advertising set true! ERROR. Setting advertising=false")
                self.advertising = false
                return
            }
            publisher.endPublish()
            NSLog("BluepeerObject: advertising stopped")
        } else {
            NSLog("BluepeerObject: no advertising to stop (no-op)")
        }
        self.publisher = nil
        self.advertising = false
        if let socket = self.serverSocket {
            socket.delegate = nil
            socket.disconnect()
            self.serverSocket = nil
            NSLog("BluepeerObject: destroyed serverSocket")
        }
    }
    
    public func startBrowsing() {
        if self.browsing == true {
            NSLog("BluepeerObject: Already browsing (no-op)")
            return
        }

        self.browser = HHServiceBrowser.init(type: self.serviceType, domain: "local.", includeP2P: true)
        guard let browser = self.browser else {
            NSLog("BluepeerObject: ERROR, could not create browser")
            return
        }
        browser.delegate = self
        self.browsing = browser.beginBrowseOverBluetoothOnly(self.overBluetoothOnly)
        NSLog("BluepeerObject: now browsing")
    }
    
    public func stopBrowsing() {
        if (self.browsing) {
            guard let browser = self.browser else {
                NSLog("BluepeerObject: browser is MIA while browsing set true! ERROR. Setting browsing=false")
                self.browsing = false
                return
            }
            browser.endBrowse()
            NSLog("BluepeerObject: browsing stopped")
        } else {
            NSLog("BluepeerObject: no browsing to stop (no-op)")
        }
        self.browser = nil
        self.browsing = false
    }
    
    
    // If specified, peers takes precedence.
    public func sendData(datas: [NSData], toPeers:[BPPeer]) throws {
        for data in datas {
            NSLog("BluepeerObject: sending data size \(data.length) to \(toPeers.count) peers")
            for peer in toPeers {
                self.sendDataInternal(peer, data: data)
            }
        }
    }
    
    public func sendData(datas: [NSData], toRole: RoleType) throws {
        let targetPeers: [BPPeer] = peers.filter({
            if toRole != .All {
                return $0.role == toRole && $0.state == .Connected
            } else {
                return $0.state == .Connected
            }
        })
    
        for data in datas {
            if data.length == 0 {
                continue
            }
            NSLog("BluepeerObject sending this data to %d peers", targetPeers.count)
            for peer in targetPeers {
                self.sendDataInternal(peer, data: data)
            }
        }
    }
    
    func dispatch_on_delegate_queue(block: dispatch_block_t) {
        if let queue = self.delegateQueue {
            dispatch_async(queue, block)
        } else {
            dispatch_async(dispatch_get_main_queue(), block)
        }
    }
    
    func sendDataInternal(peer: BPPeer, data: NSData) {
        // send header first. Then separator. Then send body.
        var length: UInt = UInt(data.length)
        let headerdata = NSData.init(bytes: &length, length: sizeof(UInt))
        peer.socket?.writeData(headerdata, withTimeout: -1, tag: DataTag.TAG_WRITING.rawValue)
        peer.socket?.writeData(self.headerTerminator, withTimeout:  -1, tag: DataTag.TAG_WRITING.rawValue)
        peer.socket?.writeData(data, withTimeout: -1, tag: DataTag.TAG_WRITING.rawValue)
    }
    
    public func getBrowser(completionBlock: Bool -> ()) -> UIViewController? {
        let initialVC = self.getStoryboard()?.instantiateInitialViewController()
        var browserVC = initialVC
        if let nav = browserVC as? UINavigationController {
            browserVC = nav.topViewController
        }
        guard let browser = browserVC as? BluepeerBrowserViewController else {
            assert(false, "ERROR - storyboard layout changed")
            return nil
        }
        browser.bluepeerObject = self
        browser.browserCompletionBlock = completionBlock
        return initialVC
    }
    
    func getStoryboard() -> UIStoryboard? {
        guard let bundlePath = NSBundle.init(forClass: BluepeerObject.self).pathForResource("Bluepeer", ofType: "bundle") else {
            assert(false, "ERROR: could not load bundle")
            return nil
        }
        return UIStoryboard.init(name: "Bluepeer", bundle: NSBundle.init(path: bundlePath))
    }
}

extension BluepeerObject : HHServicePublisherDelegate {
    public func serviceDidPublish(servicePublisher: HHServicePublisher!) {
        self.advertising = true

        // create serverSocket
        if let socket = self.serverSocket {
            socket.delegate = nil
            socket.disconnect()
            self.serverSocket = nil
        }
        
        self.serverSocket = GCDAsyncSocket.init(delegate: self, delegateQueue: self.delegateQueue ?? dispatch_get_main_queue())
        guard let serverSocket = self.serverSocket else {
            NSLog("BluepeerObject: ERROR - Could not create serverSocket")
            return
        }
        
        do {
            // TODO: Potentially filter bluetooth here, but hopefully not...
            // try self.serverSocket.acceptOnInterface("en1", port: serverPort)
            
            try serverSocket.acceptOnPort(serverPort)
        } catch {
            NSLog("BluepeerObject: ERROR accepting on serverSocket")
            return
        }
        
        NSLog("BluepeerObject: now advertising for service \(serviceType)")
    }
    
    public func serviceDidNotPublish(servicePublisher: HHServicePublisher!) {
        self.advertising = false
        NSLog("BluepeerObject: ERROR: serviceDidNotPublish")
    }
}

extension BluepeerObject : HHServiceBrowserDelegate {
    public func serviceBrowser(serviceBrowser: HHServiceBrowser!, didFindService service: HHService!, moreComing: Bool) {
        if self.browsing == false {
            return
        }
        if service.type == self.serviceType {
            service.delegate = self
            self.servicesBeingResolved.insert(service)
            service.beginResolveOnlyOverBluetooth(self.overBluetoothOnly)
        }
    }
    
    // TODO: seems like service gets killed after 4 or 5 min automatically?
    public func serviceBrowser(serviceBrowser: HHServiceBrowser!, didRemoveService service: HHService!, moreComing: Bool) {
        NSLog("BluepeerObject: didRemoveService \(service.name)")
    }
}

extension BluepeerObject : HHServiceDelegate {
    public func serviceDidResolve(service: HHService!) {
        self.servicesBeingResolved.remove(service)
        if self.browsing == false {
            return
        }
        
        guard let txtdata = service.txtData else {
            NSLog("BluepeerObject: serviceDidResolve IGNORING service because no txtData found")
            return
        }
        
        let cfdict: Unmanaged<CFDictionary>? = CFNetServiceCreateDictionaryWithTXTData(kCFAllocatorDefault, txtdata)
        guard let _ = cfdict else {
            NSLog("BluepeerObject: serviceDidResolve IGNORING service because txtData was invalid")
            return
        }
        let dict: NSDictionary = cfdict!.takeUnretainedValue()
        guard let roleData = dict["role"] as? NSData else {
            NSLog("BluepeerObject: serviceDidResolve IGNORING service because role was missing")
            return
        }
        let roleStr = String.init(data: roleData, encoding: NSUTF8StringEncoding)
        let role = RoleType.roleFromString(roleStr)
        if role == .Unknown {
            assert(false, "Expecting a role that isn't unknown here")
            return
        }
        
        NSLog("BluepeerObject: serviceDidResolve type: \(service.type), name: \(service.name), role: \(roleStr)")
        
        guard let delegate = self.sessionDelegate else {
            NSLog("BluepeerObject: WARNING, ignoring resolved service because sessionDelegate is not set")
            return
        }
        guard let addressStr = service.resolvedIPAddresses.first as? String else {
            NSLog("BluepeerObject: serviceDidResolve IGNORING service because could not get address")
            return
        }
        guard let port = service.resolvedPortNumbers.first as? NSNumber else {
            NSLog("BluepeerObject: serviceDidResolve IGNORING service because could not get port")
            return
        }
        
        self.stopBrowsing() // stop browsing once we found something to conncect to
        
        let newPeer = BPPeer.init()
        newPeer.role = role
        newPeer.displayName = service.name
        newPeer.IP = addressStr
        self.addPeer(newPeer)
        
        self.dispatch_on_delegate_queue({
            delegate.browserFoundPeer!(role, peer: newPeer) { (connect, timeoutForInvite) in
                if connect {
                    do {
                        NSLog("... trying to connect...")
                        newPeer.socket = GCDAsyncSocket.init(delegate: self, delegateQueue: self.delegateQueue ?? dispatch_get_main_queue())
                        newPeer.socket?.userData = addressStr // save the IP in the socket userdata for correlation later
                        newPeer.state = .Connecting
                        // try socket.connectToAddress(addressData, withTimeout: 20.0) // TODO: filtering to bluetooth could also happen here, but probably not a good idea.
                        try newPeer.socket?.connectToHost(addressStr, onPort: port.unsignedShortValue, withTimeout: timeoutForInvite)
                    } catch {
                        NSLog("BluepeerObject: could not start connectToAdddress.")
                    }
                } else {
                    NSLog("... got told NOT to connect.")
                    newPeer.state = .NotConnected
                }
            }
        })
    }
    
    public func serviceDidNotResolve(service: HHService!) {
        NSLog("BluepeerObject: ERROR, service did not resolve: \(service.name)")
        self.servicesBeingResolved.remove(service)
    }
    
    public func addPeer(newPeer: BPPeer) {
        let replaced = self.peers.contains(newPeer)
        self.peers.insert(newPeer)
        if replaced {
            NSLog("BluepeerObject: replaced peer with IP \(newPeer.IP)")
        } else {
            NSLog("BluepeerObject: added new peer with IP \(newPeer.IP)")
        }
    }
}


extension BluepeerObject : GCDAsyncSocketDelegate {
    
    public func socket(sock: GCDAsyncSocket, didAcceptNewSocket newSocket: GCDAsyncSocket) {
        
        if let delegate = self.sessionDelegate {
            guard let connectedHost = newSocket.connectedHost else {
                NSLog("BluepeerObject: ERROR, accepted newSocket has no connectedHost (no-op)")
                return
            }
            NSLog("BluepeerObject: accepting new connection from \(newSocket.connectedHost)")
            let newPeer = BPPeer.init()
            newPeer.state = .AwaitingAuth
            newPeer.role = .Client
            newPeer.IP = connectedHost
            self.addPeer(newPeer)

            self.dispatch_on_delegate_queue({
                delegate.peerConnectionRequest!(newPeer, invitationHandler: { (inviteAccepted) in
                    if inviteAccepted {
                        newSocket.delegate = self
                        newPeer.socket = newSocket
                        newSocket.userData = newSocket.connectedHost // so that we can always use userData as the IP/host in the rest of the code
                        newPeer.state = .Connected
                        var zero = UInt8(0) // CONVENTION: send a single 0 to show connection has been accepted, since it isn't possible to send a header for a payload of size zero except here.
                        newSocket.writeData(NSData.init(bytes: &zero, length: 1), withTimeout: -1, tag: DataTag.TAG_WRITING.rawValue)
                        NSLog("... accepted (by my delegate)")
                        self.dispatch_on_delegate_queue({
                            self.sessionDelegate?.peerDidConnect!(.Client, peer: newPeer)
                        })
                        newSocket.readDataToData(self.headerTerminator, withTimeout: -1, tag: DataTag.TAG_HEADER.rawValue)
                    } else {
                        newPeer.state = .NotConnected
                        newSocket.delegate = nil
                        newSocket.disconnect()
                        NSLog("... rejected (by my delegate)")
                    }
                })
            })
        } else {
            NSLog("BluepeerObject: WARNING, ignoring connection attempt because I don't have a sessionDelegate assigned")
        }
    }
    
    public func socket(sock: GCDAsyncSocket, didConnectToHost host: String, port: UInt16) {
        guard let sockUserdata = sock.userData as? String else {
            assert(false, "BluepeerObject: programming error, expected socket.userData to be set!")
            return
        }
        guard let peer = self.peers.filter( { $0.IP == sockUserdata }).first else {
            assert(false, "BluepeerObject: programming error, expected to find a peer already in didConnectToHost")
            return
        }
        peer.state = .AwaitingAuth
        NSLog("BluepeerObject: got to state = awaitingAuth with \(sock.connectedHost), awaiting ACK ('0')")
        sock.readDataToLength(1, withTimeout: -1, tag: DataTag.TAG_AUTH.rawValue)
    }
    
    public func socketDidDisconnect(sock: GCDAsyncSocket, withError err: NSError?) {
        guard let socketUserdata = sock.userData as? String else {
            assert(false, "BluepeerObject: ERROR, expected socket.userData in socketDidDisconnect")
            return
        }
        guard let peer = self.peers.filter( { $0.IP == socketUserdata }).first else {
            assert(false, "BluepeerObject: programming error, expected to find a peer already in didDisconnect")
            return
        }
        let oldState = peer.state
        peer.state = .NotConnected
        peer.socket = nil
        sock.userData = nil
        sock.delegate = nil
        NSLog("BluepeerObject: \(socketUserdata) disconnected")
        switch oldState {
        case .Connected:
            self.dispatch_on_delegate_queue({
                self.sessionDelegate?.peerDidDisconnect!(peer.role, peer: peer)
            })
        case .NotConnected:
            assert(false, "ERROR: state is being tracked wrong")
        case .Connecting, .AwaitingAuth:
            self.dispatch_on_delegate_queue({
                self.sessionDelegate?.peerConnectionAttemptFailed!(peer.role, peer: peer, isAuthRejection: oldState == .AwaitingAuth)
            })
        }
    }
    
    public func socket(sock: GCDAsyncSocket, didReadData data: NSData, withTag tag: Int) {
        guard let sockUserdata = sock.userData as? String else {
            assert(false, "Error, expect all sockets to have userdata set")
            return
        }
        guard let peer = self.peers.filter( { $0.IP == sockUserdata }).first else {
            assert(false, "Error, I should know peers i receive data from!")
            return
        }

        if tag == DataTag.TAG_AUTH.rawValue {
            assert(data.length == 1, "ERROR: not right length of bytes")
            var ack: UInt8 = 1
            data.getBytes(&ack, length: 1)
            assert(ack == 0, "ERROR: not the right ACK")
            assert(peer.state == .AwaitingAuth, "ERROR: expect I only get this while awaiting auth")
            peer.state = .Connected
            self.dispatch_on_delegate_queue({
                self.sessionDelegate?.peerDidConnect!(peer.role, peer: peer)
            })
            sock.readDataToData(self.headerTerminator, withTimeout: -1, tag: DataTag.TAG_HEADER.rawValue)
        } else if tag == DataTag.TAG_HEADER.rawValue {
            // first, strip the trailing headerTerminator
            let dataWithoutTerminator = data.subdataWithRange(NSRange.init(location: 0, length: data.length - self.headerTerminator.length))
            var length: UInt = 0
            dataWithoutTerminator.getBytes(&length, length: sizeof(UInt))
            NSLog("BluepeerObject: got header, reading %lu bytes...", length)
            sock.readDataToLength(length, withTimeout: -1, tag: DataTag.TAG_BODY.rawValue)
        } else {
            self.dispatch_on_delegate_queue({
                self.dataDelegate?.didReceiveData(data, fromPeer: peer)
            })
            sock.readDataToData(self.headerTerminator, withTimeout: -1, tag: DataTag.TAG_HEADER.rawValue)
        }
    }
}

extension BluepeerObject: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(peripheral: CBPeripheralManager) {
        NSLog("Bluetooth status: ")
        switch (self.bluetoothPeripheralManager.state) {
        case .Unknown:
            NSLog("Unknown")
            self.bluetoothState = .Unknown
        case .Resetting:
            NSLog("Resetting")
            self.bluetoothState = .Other
        case .Unsupported:
            NSLog("Unsupported")
            self.bluetoothState = .Other
        case .Unauthorized:
            NSLog("Unauthorized")
            self.bluetoothState = .Other
        case .PoweredOff:
            NSLog("PoweredOff")
            self.bluetoothState = .PoweredOff
        case .PoweredOn:
            NSLog("PoweredOn")
            self.bluetoothState = .PoweredOn
        }
        self.bluetoothBlock?(bluetoothState: self.bluetoothState)
    }
}

extension NSCharacterSet {
    func containsCharacter(c:Character) -> Bool {
        let s = String(c)
        let result = s.rangeOfCharacterFromSet(self)
        return result != nil
    }
}