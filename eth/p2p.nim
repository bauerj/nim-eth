# nim-eth
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[tables, algorithm, random],
  bearssl, chronos, chronos/timer, chronicles,
  ./keys, ./common/eth_types, ./p2p/private/p2p_types,
  ./p2p/[kademlia, discovery, enode, peer_pool, rlpx]

export
  p2p_types, rlpx, enode, kademlia

proc addCapability*(node: var EthereumNode, p: ProtocolInfo)
    {.raises: [Defect].} =
  doAssert node.connectionState == ConnectionState.None

  let pos = lowerBound(node.protocols, p, rlpx.cmp)
  node.protocols.insert(p, pos)
  node.capabilities.insert(p.asCapability, pos)

  if p.networkStateInitializer != nil:
    node.protocolStates[p.index] = p.networkStateInitializer(node)

template addCapability*(node: var EthereumNode, Protocol: type) =
  addCapability(node, Protocol.protocolInfo)

proc newEthereumNode*(keys: KeyPair,
                      address: Address,
                      networkId: NetworkId,
                      chain: AbstractChainDB,
                      clientId = "nim-eth-p2p/0.2.0", # TODO: read this value from nimble somehow
                      addAllCapabilities = true,
                      useCompression: bool = false,
                      minPeers = 10,
                      rng = newRng()): EthereumNode {.raises: [Defect].} =

  if rng == nil: # newRng could fail
    raise (ref Defect)(msg: "Cannot initialize RNG")

  new result
  result.keys = keys
  result.networkId = networkId
  result.clientId = clientId
  result.protocols.newSeq 0
  result.capabilities.newSeq 0
  result.address = address
  result.connectionState = ConnectionState.None
  result.rng = rng

  when useSnappy:
    result.protocolVersion = if useCompression: devp2pSnappyVersion
                             else: devp2pVersion

  result.protocolStates.newSeq allProtocols.len

  result.peerPool = newPeerPool(result, networkId,
                                keys, nil,
                                clientId, address.tcpPort,
                                minPeers = minPeers)

  if addAllCapabilities:
    for p in allProtocols:
      result.addCapability(p)

proc processIncoming(server: StreamServer,
                     remote: StreamTransport): Future[void] {.async, gcsafe.} =
  var node = getUserData[EthereumNode](server)
  let peer = await node.rlpxAccept(remote)
  if not peer.isNil:
    trace "Connection established (incoming)", peer
    if node.peerPool != nil:
      node.peerPool.connectingNodes.excl(peer.remote)
      node.peerPool.addPeer(peer)

proc listeningAddress*(node: EthereumNode): ENode =
  node.toENode()

proc startListening*(node: EthereumNode) =
  # TODO allow binding to specific IP
  
  var ta: TransportAddress
  ta = initTAddress(IPv6_any(), node.address.tcpPort)

  let nativeSock = createNativeSocket(ta.getDomain(), SockType.SOCK_STREAM,
                                      nativesockets.Protocol.IPPROTO_TCP)
  var asyncSock: AsyncFD = AsyncFD(nativeSock)
  let dualstack = asyncSock.setSockOpt(posix.IPPROTO_IPV6, posix.IPV6_V6ONLY, 0)

  if nativeSock == osInvalidSocket or dualstack == false:
    ta = initTAddress(IPv4_any(), node.address.tcpPort)
    asyncSock = asyncInvalidSocket

  if node.listeningServer == nil:
    node.listeningServer = createStreamServer(ta, processIncoming,
                                              {ReuseAddr},
                                              sock = asyncSock,
                                              udata = cast[pointer](node))
  node.listeningServer.start()
  info "RLPx listener up", self = node.listeningAddress

proc connectToNetwork*(node: EthereumNode,
                       bootstrapNodes: seq[ENode],
                       startListening = true,
                       enableDiscovery = true) {.async.} =
  doAssert node.connectionState == ConnectionState.None

  node.connectionState = Connecting
  node.discovery = newDiscoveryProtocol(node.keys.seckey,
                                        node.address,
                                        bootstrapNodes)
  node.peerPool.discovery = node.discovery

  if startListening:
    p2p.startListening(node)

  if enableDiscovery:
    node.discovery.open()
    await node.discovery.bootstrap()
    node.peerPool.start()
  else:
    info "Discovery disabled"

  while node.peerPool.connectedNodes.len == 0:
    trace "Waiting for more peers", peers = node.peerPool.connectedNodes.len
    await sleepAsync(500.milliseconds)

proc stopListening*(node: EthereumNode) =
  node.listeningServer.stop()

iterator peers*(node: EthereumNode): Peer =
  for peer in node.peerPool.peers:
    yield peer

iterator peers*(node: EthereumNode, Protocol: type): Peer =
  for peer in node.peerPool.peers(Protocol):
    yield peer

iterator protocolPeers*(node: EthereumNode, Protocol: type): auto =
  mixin state
  for peer in node.peerPool.peers(Protocol):
    yield peer.state(Protocol)

iterator randomPeers*(node: EthereumNode, maxPeers: int): Peer =
  # TODO: this can be implemented more efficiently

  # XXX: this doesn't compile, why?
  # var peer = toSeq node.peers
  var peers = newSeqOfCap[Peer](node.peerPool.connectedNodes.len)
  for peer in node.peers: peers.add(peer)

  shuffle(peers)
  for i in 0 ..< min(maxPeers, peers.len):
    yield peers[i]

proc randomPeer*(node: EthereumNode): Peer =
  let peerIdx = rand(node.peerPool.connectedNodes.len)
  var i = 0
  for peer in node.peers:
    if i == peerIdx: return peer
    inc i

iterator randomPeers*(node: EthereumNode, maxPeers: int, Protocol: type): Peer =
  var peers = newSeqOfCap[Peer](node.peerPool.connectedNodes.len)
  for peer in node.peers(Protocol):
    peers.add(peer)
  shuffle(peers)
  if peers.len > maxPeers: peers.setLen(maxPeers)
  for p in peers: yield p

proc randomPeerWith*(node: EthereumNode, Protocol: type): Peer =
  var candidates = newSeq[Peer]()
  for p in node.peers(Protocol):
    candidates.add(p)
  if candidates.len > 0:
    return candidates.rand()

proc getPeer*(node: EthereumNode, peerId: NodeId, Protocol: type): Option[Peer] =
  for peer in node.peers(Protocol):
    if peer.remote.id == peerId:
      return some(peer)
