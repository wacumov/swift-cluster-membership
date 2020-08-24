//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
import enum Dispatch.DispatchTimeInterval
import Logging
import NIO
import SWIM

/// The SWIM shell is responsible for driving all interactions of the `SWIM.Instance` with the outside world.
///
/// WARNING: ALL external invocations MUST be executed on the Shell's `EventLoop`, failure to do so will c
///
/// - SeeAlso: `SWIM.Instance` for detailed documentation about the SWIM protocol implementation.
public final class SWIMNIOShell {
    var swim: SWIM.Instance!
    var settings: SWIM.Settings {
        self.swim.settings
    }

    public var log: Logger

    let eventLoop: EventLoop
    let channel: Channel

    let myself: SWIM.NIOPeer
    public var peer: SWIMPeer {
        self.myself
    }

    let onMemberStatusChange: (SWIM.MemberStatusChangedEvent) -> Void

    public var node: Node {
        self.myself.node
    }

    /// Cancellable of the periodicPingTimer (if it was kicked off)
    private var nextPeriodicTickCancellable: SWIMCancellable?

    internal init(
        node: Node,
        settings: SWIM.Settings,
        channel: Channel,
        startPeriodicPingTimer: Bool = true,
        onMemberStatusChange: @escaping (SWIM.MemberStatusChangedEvent) -> Void
    ) {
        self.log = settings.logger

        self.channel = channel
        self.eventLoop = channel.eventLoop

        let myself = SWIM.NIOPeer(node: node, channel: channel)
        self.myself = myself
        self.swim = SWIM.Instance(settings: settings, myself: myself)

        self.onMemberStatusChange = onMemberStatusChange
        self.onStart(startPeriodicPingTimer: startPeriodicPingTimer)
    }

    /// Initialize timers and other after-initialized tasks
    private func onStart(startPeriodicPingTimer: Bool) {
        // Immediately announce that "we" are alive
        self.announceMembershipChange(.init(previousStatus: nil, member: self.swim.myselfMember))

        // Immediately attempt to connect to initial contact points
        self.settings.initialContactPoints.forEach { node in
            self.receiveStartMonitoring(node: node)
        }

        if startPeriodicPingTimer {
            // Kick off timer for periodically pinging random cluster member (i.e. the periodic Gossip)
            self.handlePeriodicProtocolPeriodTick()
        }
    }

    public func receiveShutdown() {
        guard self.eventLoop.inEventLoop else {
            return self.eventLoop.execute {
                self.receiveShutdown()
            }
        }

        self.nextPeriodicTickCancellable?.cancel()
        self.log.info("\(Self.self) shutdown")
    }

    /// Start a *single* timer, to run the passed task after given delay.
    @discardableResult
    private func schedule(key: String, delay: DispatchTimeInterval, _ task: @escaping () -> Void) -> SWIMCancellable {
        self.eventLoop.assertInEventLoop()

        let scheduled: Scheduled<Void> = self.eventLoop.scheduleTask(in: delay.toNIO) { () in task() }
        return SWIMCancellable { scheduled.cancel() }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Receiving messages

    public func receiveMessage(message: SWIM.Message) {
        guard self.eventLoop.inEventLoop else {
            return self.eventLoop.execute {
                self.receiveMessage(message: message)
            }
        }

        self.tracelog(.receive, message: "\(message)")

        switch message {
        case .ping(let replyTo, let payload, let sequenceNumber):
            self.receivePing(replyTo: replyTo, payload: payload, sequenceNumber: sequenceNumber)

        case .pingRequest(let target, let replyTo, let payload, let sequenceNumber):
            self.receivePingRequest(target: target, replyTo: replyTo, payload: payload, sequenceNumber: sequenceNumber)

        case .response(let pingResponse):
            self.receivePingResponse(response: pingResponse, pingRequestOriginPeer: nil)
        }
    }

    /// Allows for typical local interactions with the shell
    public func receiveLocalMessage(message: SWIM.LocalMessage) {
        guard self.eventLoop.inEventLoop else {
            return self.eventLoop.execute {
                self.receiveLocalMessage(message: message)
            }
        }

        self.tracelog(.receive, message: "\(message)")

        switch message {
        case .monitor(let node):
            self.receiveStartMonitoring(node: node)

        case .confirmDead(let node):
            self.receiveConfirmDead(deadNode: node)
        }
    }

    private func receivePing(replyTo: SWIMPingOriginPeer, payload: SWIM.GossipPayload, sequenceNumber: SWIM.SequenceNumber) {
        guard self.eventLoop.inEventLoop else {
            return self.eventLoop.execute {
                self.receivePing(replyTo: replyTo, payload: payload, sequenceNumber: sequenceNumber)
            }
        }

        self.log.debug("Received ping@\(sequenceNumber)", metadata: self.swim.metadata([
            "swim/ping/replyTo": "\(replyTo.node)",
            "swim/ping/payload": "\(payload)",
            "swim/ping/seqNr": "\(sequenceNumber)",
        ]))

        let directives: [SWIM.Instance.PingDirective] = self.swim.onPing(pingOrigin: replyTo, payload: payload, sequenceNumber: sequenceNumber)
        directives.forEach { directive in
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipPayloadProcessedDirective(gossipDirective)

            case .sendAck(let myself, let incarnation, let payload, let identifier):
                self.tracelog(.reply(to: replyTo), message: "\(directive)")
                assert(myself.node == self.node, "Since we are replying to a ping, the target has to be myself node")
                replyTo.peer(self.channel).ack(acknowledging: identifier, target: self.myself, incarnation: incarnation, payload: payload)
            }
        }
    }

    private func receivePingRequest(
        target: SWIM.NIOPeer,
        replyTo: SWIM.NIOPeer,
        payload: SWIM.GossipPayload,
        sequenceNumber pingReqSequenceNr: SWIM.SequenceNumber
    ) {
        guard self.eventLoop.inEventLoop else {
            return self.eventLoop.execute {
                self.receivePingRequest(target: target, replyTo: replyTo, payload: payload, sequenceNumber: pingReqSequenceNr)
            }
        }

        self.log.trace("Received pingRequest", metadata: [
            "swim/replyTo": "\(replyTo.node)",
            "swim/target": "\(target.node)",
            "swim/gossip/payload": "\(payload)",
        ])

        let directives: [SWIM.Instance.PingRequestDirective] = self.swim.onPingRequest(target: target, replyTo: replyTo, payload: payload)
        directives.forEach { directive in
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipPayloadProcessedDirective(gossipDirective)

            case .sendPing(let target, let pingRequestOriginPeer, let timeout, let sequenceNumber):
                self.sendPing(to: target, pingRequestOriginPeer: pingRequestOriginPeer, timeout: timeout, sequenceNumber: sequenceNumber)

            case .ignore:
                self.log.trace("Ignoring ping request", metadata: self.swim.metadata([
                    "swim/pingReq/sequenceNumber": "\(pingReqSequenceNr)",
                    "swim/pingReq/target": "\(target)",
                    "swim/pingReq/replyTo": "\(replyTo)",
                ]))
            }
        }
    }

    /// - parameter pingRequestOrigin: is set only when the ping that this is a reply to was originated as a `pingReq`.
    func receivePingResponse(
        response: SWIM.PingResponse,
        pingRequestOriginPeer: SWIMPingOriginPeer?
    ) {
        guard self.eventLoop.inEventLoop else {
            return self.eventLoop.execute {
                self.receivePingResponse(response: response, pingRequestOriginPeer: pingRequestOriginPeer)
            }
        }

        let sequenceNumber = response.sequenceNumber

        self.log.debug("Receive ping response: \(response)", metadata: self.swim.metadata([
            "swim/pingRequestOriginPeer": "\(pingRequestOriginPeer, orElse: "nil")",
            "swim/response/sequenceNumber": "\(sequenceNumber)",
        ]))

        let directives = self.swim.onPingResponse(response: response, pingRequestOrigin: pingRequestOriginPeer)
        // optionally debug log all directives here
        directives.forEach { directive in
            switch directive {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipPayloadProcessedDirective(gossipDirective)

            case .sendAck(let pingRequestOrigin, let acknowledging, let target, let incarnation, let payload):
                // FIXME: cleanup of that additional peer resolving
                pingRequestOrigin.peer(self.channel).ack(acknowledging: acknowledging, target: target, incarnation: incarnation, payload: payload)

            case .sendNack(let pingRequestOrigin, let acknowledging, let target):
                // FIXME: cleanup of that additional peer resolving
                pingRequestOrigin.peer(self.channel).nack(acknowledging: acknowledging, target: target)

            case .sendPingRequests(let pingRequestDirective):
                self.sendPingRequests(pingRequestDirective)
            }
        }
    }

    func receiveEveryPingRequestResponse(result: SWIM.PingResponse, pingedPeer: SWIMAddressablePeer) {
        guard self.eventLoop.inEventLoop else {
            return self.eventLoop.execute {
                self.receiveEveryPingRequestResponse(result: result, pingedPeer: pingedPeer)
            }
        }
        self.tracelog(.receive(pinged: pingedPeer), message: "\(result)")
        self.swim.onEveryPingRequestResponse(result, pingedMember: pingedPeer)
    }

    func receivePingRequestResponse(result: SWIM.PingResponse, pingedPeer: SWIMAddressablePeer) {
        guard self.eventLoop.inEventLoop else {
            return self.eventLoop.execute {
                self.receivePingRequestResponse(result: result, pingedPeer: pingedPeer)
            }
        }

        self.tracelog(.receive(pinged: pingedPeer), message: "\(result)")
        // TODO: do we know here WHO replied to us actually? We know who they told us about (with the ping-req), could be useful to know

        // FIXME: change those directives
        let directives: [SWIM.Instance.PingRequestResponseDirective] = self.swim.onPingRequestResponse(result, pingedMember: pingedPeer)
        directives.forEach {
            switch $0 {
            case .gossipProcessed(let gossipDirective):
                self.handleGossipPayloadProcessedDirective(gossipDirective)

            case .alive(let previousStatus):
                self.log.debug("Member [\(pingedPeer.node)] marked as alive")

                if previousStatus.isUnreachable, let member = swim.member(for: pingedPeer) {
                    let event = SWIM.MemberStatusChangedEvent(previousStatus: previousStatus, member: member) // FIXME: make SWIM emit an option of the event
                    self.announceMembershipChange(event)
                }

            case .newlySuspect(let previousStatus, let suspect):
                self.log.debug("Member [\(suspect)] marked as suspect")
                let event = SWIM.MemberStatusChangedEvent(previousStatus: previousStatus, member: suspect) // FIXME: make SWIM emit an option of the event
                self.announceMembershipChange(event)

            case .nackReceived:
                self.log.debug("Received `nack` from indirect probing of [\(pingedPeer)]")
            case let other:
                self.log.trace("Handled ping request response, resulting directive: \(other), was ignored.") // TODO: explicitly list all cases
            }
        }
    }

    private func announceMembershipChange(_ change: SWIM.MemberStatusChangedEvent) {
        self.onMemberStatusChange(change)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Sending ping, ping-req and friends

    /// Send a `ping` message to the `target` peer.
    ///
    /// - parameter pingRequestOrigin: is set only when the ping that this is a reply to was originated as a `pingReq`.
    func sendPing(
        to target: SWIMAddressablePeer,
        pingRequestOriginPeer: SWIMPingOriginPeer?,
        timeout: DispatchTimeInterval,
        sequenceNumber: SWIM.SequenceNumber
    ) {
        let payload = self.swim.makeGossipPayload(to: target)

        self.log.trace("Sending ping", metadata: self.swim.metadata([
            "swim/target": "\(target.node)",
            "swim/gossip/payload": "\(payload)",
            "swim/timeout": "\(timeout)",
        ]))

        let targetPeer = target.peer(self.channel)

        self.tracelog(.send(to: targetPeer), message: "ping(replyTo: \(self.peer), payload: \(payload), sequenceNr: \(sequenceNumber))")
        targetPeer.ping(payload: payload, from: self.peer, timeout: timeout, sequenceNumber: sequenceNumber) { (result: Result<SWIM.PingResponse, Error>) in
            switch result {
            case .success(let response):
                self.receivePingResponse(response: response, pingRequestOriginPeer: pingRequestOriginPeer)
            case .failure(let error as SWIMNIOTimeoutError):
                self.receivePingResponse(response: .timeout(target: target, pingRequestOrigin: pingRequestOriginPeer, timeout: error.timeout, sequenceNumber: sequenceNumber), pingRequestOriginPeer: pingRequestOriginPeer)
            case .failure(let error):
                self.log.debug("Failed to ping", metadata: ["ping/target": "\(target)", "error": "\(error)"])
                self.receivePingResponse(response: .timeout(target: target, pingRequestOrigin: pingRequestOriginPeer, timeout: timeout, sequenceNumber: sequenceNumber), pingRequestOriginPeer: pingRequestOriginPeer)
            }
        }
    }

    func sendPingRequests(_ directive: SWIM.Instance.SendPingRequestDirective) {
        // We are only interested in successful pings, as a single success tells us the node is
        // still alive. Therefore we propagate only the first success, but no failures.
        // The failure case is handled through the timeout of the whole operation.
        let firstSuccessPromise = self.eventLoop.makePromise(of: SWIM.PingResponse.self)
        let pingTimeout = self.swim.dynamicLHMPingTimeout
        let target = directive.target
        for pingRequest in directive.requestDetails {
            let memberToPingRequestThrough = pingRequest.memberToPingRequestThrough
            let payload = pingRequest.payload
            let sequenceNumber = pingRequest.sequenceNumber

            self.log.trace("Sending ping request for [\(target)] to [\(memberToPingRequestThrough)] with payload: \(payload)")

            let peerToPingRequestThrough = memberToPingRequestThrough.node.peer(on: self.channel)

            self.tracelog(.send(to: peerToPingRequestThrough), message: "pingRequest(target: \(target), replyTo: \(self.peer), payload: \(payload), sequenceNumber: \(sequenceNumber))")
            peerToPingRequestThrough.pingRequest(target: target, payload: payload, from: self.peer, timeout: pingTimeout, sequenceNumber: sequenceNumber) { result in
                switch result {
                case .success(let response):
                    self.receiveEveryPingRequestResponse(result: response, pingedPeer: target)

                    if case .ack = response {
                        // We only cascade successful ping responses (i.e. `ack`s);
                        //
                        // While this has a slight timing implication on time timeout of the pings -- the node that is last
                        // in the list that we ping, has slightly less time to fulfil the "total ping timeout"; as we set a total timeout on the entire `firstSuccess`.
                        // In practice those timeouts will be relatively large (seconds) and the few millis here should not have a large impact on correctness.
                        firstSuccessPromise.succeed(response)
                    }
                case .failure(let error):
                    self.receiveEveryPingRequestResponse(result: .timeout(target: target, pingRequestOrigin: self.myself, timeout: pingTimeout, sequenceNumber: sequenceNumber), pingedPeer: target)
                    // these are generally harmless thus we do not want to log them on higher levels
                    self.log.trace("Failed pingRequest", metadata: [
                        "swim/target": "\(target)",
                        "swim/payload": "\(payload)",
                        "swim/pingTimeout": "\(pingTimeout)",
                        "error": "\(error)",
                    ])
                }
            }
        }

        // guaranteed to be on "our" EL
        firstSuccessPromise.futureResult.whenComplete {
            switch $0 {
            case .success(let response):
                self.receivePingRequestResponse(result: response, pingedPeer: target)
            case .failure(let error):
                self.log.debug("Failed to pingRequest via \(directive.requestDetails.count) peers", metadata: ["pingRequest/target": "\(target)", "error": "\(error)"])
                self.receivePingRequestResponse(result: .timeout(target: target, pingRequestOrigin: nil, timeout: pingTimeout, sequenceNumber: 0), pingedPeer: target) // sequence number does not matter
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Handling local messages

    /// Periodic (scheduled) function to ping ("probe") a random member.
    ///
    /// This is the heart of the periodic gossip performed by SWIM.
    func handlePeriodicProtocolPeriodTick() {
        self.eventLoop.assertInEventLoop()
        func handlePeriodicProtocolPeriodTick0() {
            // needs to be done first, so we can gossip out the most up to date state
            self.checkSuspicionTimeouts() // FIXME: Push into SWIM's onPeriodicPingTick

            let directive = self.swim.onPeriodicPingTick()
            switch directive {
            case .ignore:
                self.log.trace("Skipping periodic ping", metadata: self.swim.metadata)

            case .sendPing(let target, let timeout, let sequenceNumber):
                self.log.trace("Periodic ping random member, among: \(self.swim.otherMemberCount)", metadata: self.swim.metadata)
                self.sendPing(to: target, pingRequestOriginPeer: nil, timeout: timeout, sequenceNumber: sequenceNumber)
            }
        }
        handlePeriodicProtocolPeriodTick0()

        self.nextPeriodicTickCancellable = self.schedule(key: SWIMNIOShell.periodicPingKey, delay: self.swim.dynamicLHMProtocolInterval) {
            self.handlePeriodicProtocolPeriodTick()
        }
    }

    /// Extra functionality, allowing external callers to ask this swim shell to start monitoring a specific node.
    // TODO: Add some attempts:Int + maxAttempts: Int and handle them appropriately; https://github.com/apple/swift-cluster-membership/issues/32
    private func receiveStartMonitoring(node: Node) {
        guard self.eventLoop.inEventLoop else {
            return self.eventLoop.execute {
                self.receiveStartMonitoring(node: node)
            }
        }

        guard self.node.withoutUID != node.withoutUID else {
            return // no need to monitor ourselves, nor a replacement of us (if node is our replacement, we should have been dead already)
        }

        let targetPeer = node.peer(on: self.channel)

        guard !self.swim.isMember(targetPeer, ignoreUID: true) else {
            return // we're done, the peer has become a member!
        }

        let sequenceNumber = self.swim.nextSequenceNumber()
        self.tracelog(.send(to: targetPeer), message: "ping(replyTo: \(self.peer), payload: .none, sequenceNr: \(sequenceNumber))")
        targetPeer.ping(payload: .none, from: self.peer, timeout: .seconds(1), sequenceNumber: sequenceNumber) { (result: Result<SWIM.PingResponse, Error>) in
            switch result {
            case .success(let response):
                self.receivePingResponse(response: response, pingRequestOriginPeer: nil)
            case .failure(let error):
                self.log.debug("Failed to initial ping, will try again", metadata: ["ping/target": "\(node)", "error": "\(error)"])
                // TODO: implement via re-trying a few times and then giving up https://github.com/apple/swift-cluster-membership/issues/32
                self.eventLoop.scheduleTask(in: .seconds(5)) {
                    self.log.info("(Re)-Attempt ping to initial contact point: \(node)")
                    self.receiveStartMonitoring(node: node)
                }
            }
        }
    }

    // TODO: not presently used in the SWIMNIO + udp implementation, make use of it or remove? other impls do need this functionality.
    private func receiveConfirmDead(deadNode node: Node) {
        guard case .enabled = self.settings.extensionUnreachability else {
            self.log.warning("Received confirm .dead for [\(node)], however shell is not configured to use unreachable state, thus this results in no action.")
            return
        }

        // We are diverging from the SWIM paper here in that we store the `.dead` state, instead
        // of removing the node from the member list. We do that in order to prevent dead nodes
        // from being re-added to the cluster.
        // TODO: add time of death to the status?
        // TODO: GC tombstones after a day?

        guard let member = swim.member(for: node) else {
            self.log.warning("Attempted to confirm .dead [\(node)], yet no such member known", metadata: self.swim.metadata)
            return
        }

        // even if it's already dead, swim knows how to handle all the cases:
        let directive = self.swim.confirmDead(peer: member.peer)
        switch directive {
        case .ignored:
            self.log.warning("Attempted to confirmDead node \(node) was ignored, was already dead?", metadata: [
                "swim/member": "\(optional: swim.member(for: node))",
            ])

        case .applied(let change):
            self.log.trace("Confirmed node as .dead", metadata: self.swim.metadata([
                "swim/member": "\(optional: swim.member(for: node))",
            ]))
            self.tryAnnounceMemberReachability(change: change)
        }
    }

    // FIXME: move into SWIM on the "on periodic tick"
    func checkSuspicionTimeouts() {
        self.log.trace(
            "Checking suspicion timeouts...",
            metadata: [
                "swim/suspects": "\(self.swim.suspects)",
                "swim/all": Logger.MetadataValue.array(self.swim.allMembers.map { "\($0)" }),
                "swim/protocolPeriod": "\(self.swim.protocolPeriod)",
            ]
        )

        for suspect in self.swim.suspects {
            if case .suspect(_, let suspectedBy) = suspect.status {
                let suspicionTimeout = self.swim.suspicionTimeout(suspectedByCount: suspectedBy.count)
                self.log.trace(
                    "Checking suspicion timeout for: \(suspect)...",
                    metadata: [
                        "swim/suspect": "\(suspect)",
                        "swim/suspectedBy": "\(suspectedBy.count)",
                        "swim/suspicionTimeout": "\(suspicionTimeout)",
                    ]
                )

                // proceed with suspicion escalation to .unreachable if the timeout period has been exceeded
                // We don't use Deadline because tests can override TimeSource
                guard let startTime = suspect.suspicionStartedAt,
                    self.swim.isExpired(deadline: startTime + suspicionTimeout.nanoseconds) else {
                    continue // skip, this suspect is not timed-out yet
                }

                guard let incarnation = suspect.status.incarnation else {
                    // suspect had no incarnation number? that means it is .dead already and should be recycled soon
                    return
                }

                var unreachableSuspect = suspect
                if swim.settings.extensionUnreachability == .enabled {
                    unreachableSuspect.status = .unreachable(incarnation: incarnation)
                } else {
                    unreachableSuspect.status = .dead
                }
                self.markMember(latest: unreachableSuspect)
            }
        }

        // metrics.recordSWIM.Members(self.swim.allMembers) // FIXME metrics
    }

    // FIXME: push into swim
    private func markMember(latest: SWIM.Member) {
        switch self.swim.mark(latest.peer, as: latest.status) {
        case .applied(let previousStatus, _):
            self.log.trace(
                "Marked \(latest.node) as \(latest.status), announcing reachability change",
                metadata: [
                    "swim/member": "\(latest)",
                    "swim/previousStatus": "\(previousStatus, orElse: "nil")",
                ]
            )
            self.tryAnnounceMemberReachability(change: SWIM.MemberStatusChangedEvent(previousStatus: previousStatus, member: latest))
        case .ignoredDueToOlderStatus:
            () // self.log.trace("No change \(latest), currentStatus remains [\(currentStatus)]. No reachability change to announce")
        }
    }

    func handleGossipPayloadProcessedDirective(_ directive: SWIM.Instance.GossipProcessedDirective) {
        switch directive {
        case .ignored(let level, let message): // TODO: allow the instance to log
            if let level = level, let message = message {
                self.log.log(level: level, message, metadata: self.swim.metadata)
            }

        case .applied(let change, _, _):
            self.tryAnnounceMemberReachability(change: change)
        }
    }

    /// Announce to the a change in reachability of a member.
    private func tryAnnounceMemberReachability(change: SWIM.MemberStatusChangedEvent?) {
        guard let change = change else {
            // this means it likely was a change to the same status or it was about us, so we do not need to announce anything
            return
        }

        guard change.isReachabilityChange else {
            // the change is from a reachable to another reachable (or an unreachable to another unreachable-like (e.g. dead) state),
            // and thus we must not act on it, as the shell was already notified before about the change into the current status.
            return
        }

//        // Log the transition
//        switch change.status {
//        case .unreachable:
//            self.log.info(
//                "Node \(change.member.node) determined [.unreachable]!",
//                metadata: [
//                    "swim/member": "\(change.member)",
//                ]
//            )
//        default:
//            self.log.info(
//                "Node \(change.member.node) determined [.\(change.status)] (was [\(change.previousStatus, orElse: "nil")]).",
//                metadata: [
//                    "swim/member": "\(change.member)",
//                ]
//            )
//        }

        // emit the SWIM.MemberStatusChange as user event
        self.announceMembershipChange(change)
    }

}

extension SWIMNIOShell {
    static let periodicPingKey = "swim/periodic-ping"
}

/// Reachability indicates a failure detectors assessment of the member node's reachability,
/// i.e. whether or not the node is responding to health check messages.
///
/// Unlike `MemberStatus` (which may only move "forward"), reachability may flip back and forth between `.reachable`
/// and `.unreachable` states multiple times during the lifetime of a member.
///
/// - SeeAlso: `SWIM` for a distributed failure detector implementation which may issue unreachable events.
public enum MemberReachability: String, Equatable {
    /// The member is reachable and responding to failure detector probing properly.
    case reachable
    /// Failure detector has determined this node as not reachable.
    /// It may be a candidate to be downed.
    case unreachable
}

struct SWIMCancellable {
    let cancel: () -> Void

    init(_ cancel: @escaping () -> Void) {
        self.cancel = cancel
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Peer "resolve"

extension SWIMAddressablePeer {
    /// Since we're an implementation over UDP, all messages are sent to the same channel anyway,
    /// and simply wrapped in `NIO.AddressedEnvelope`, thus we can easily take any addressable and
    /// convert it into a real NIO peer by simply providing the channel we're running on.
    func peer(_ channel: Channel) -> SWIM.NIOPeer {
        self.node.peer(on: channel)
    }
}

extension ClusterMembership.Node {
    /// Since we're an implementation over UDP, all messages are sent to the same channel anyway,
    /// and simply wrapped in `NIO.AddressedEnvelope`, thus we can easily take any addressable and
    /// convert it into a real NIO peer by simply providing the channel we're running on.
    func peer(on channel: Channel) -> SWIM.NIOPeer {
        .init(node: self, channel: channel)
    }
}
