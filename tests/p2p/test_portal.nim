# nim-eth - Portal Network
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  chronos, testutils/unittests,
  ../../eth/keys, # for rng
  ../../eth/p2p/discoveryv5/protocol as discv5_protocol,
  ../../eth/p2p/portal/protocol as portal_protocol,
  ./discv5_test_helper

proc random(T: type UInt256, rng: var BrHmacDrbgContext): T =
  var key: UInt256
  brHmacDrbgGenerate(addr rng, addr key, csize_t(sizeof(key)))

  key

procSuite "Portal Tests":
  let rng = newRng()

  asyncTest "Portal Ping/Pong":
    let
      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20302))
      node2 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))

      proto1 = PortalProtocol.new(node1)
      proto2 = PortalProtocol.new(node2)

    let pong = await proto1.ping(proto2.baseProtocol.localNode)

    check:
      pong.isOk()
      pong.get().enrSeq == 1'u64
      pong.get().dataRadius == UInt256.high()

    await node1.closeWait()
    await node2.closeWait()

  asyncTest "Portal FindNode/Nodes":
    let
      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20302))
      node2 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))

      proto1 = PortalProtocol.new(node1)
      proto2 = PortalProtocol.new(node2)

    block: # Find itself
      let nodes = await proto1.findNode(proto2.baseProtocol.localNode,
        List[uint16, 256](@[0'u16]))

      check:
        nodes.isOk()
        nodes.get().total == 1'u8
        nodes.get().enrs.len() == 1

    block: # Find nothing
      let nodes = await proto1.findNode(proto2.baseProtocol.localNode,
        List[uint16, 256](@[]))

      check:
        nodes.isOk()
        nodes.get().total == 1'u8
        nodes.get().enrs.len() == 0

    block: # Find for distance
      # TODO: Add test when implemented
      discard

    await node1.closeWait()
    await node2.closeWait()

  asyncTest "Portal FindContent/FoundContent":
    let
      node1 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20302))
      node2 = initDiscoveryNode(
        rng, PrivateKey.random(rng[]), localAddress(20303))

      proto1 = PortalProtocol.new(node1)
      proto2 = PortalProtocol.new(node2)

    let contentKey = ByteList(@(UInt256.random(rng[]).toBytes()))

    let foundContent = await proto1.findContent(proto2.baseProtocol.localNode,
      contentKey)

    check:
      foundContent.isOk()
      # TODO: adjust when implemented
      foundContent.get().enrs.len() == 0
      foundContent.get().payload.len() == 0

    await node1.closeWait()
    await node2.closeWait()
