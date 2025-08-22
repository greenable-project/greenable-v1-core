// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {MissionProtocol} from "../src/MissionProtocol.sol";
import {MissionToken} from "../src/missionToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract MockKRW is ERC20 {
    constructor() ERC20("Korean Won", "KRW") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MissionProtocolTest is Test {
    MissionProtocol public protocol;
    MockKRW public krw;

    address public government = makeAddr("government");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public merchant1 = makeAddr("merchant1");
    address public merchant2 = makeAddr("merchant2");
    address public verifier1 = makeAddr("verifier1");
    address public verifier2 = makeAddr("verifier2");

    // 검증자의 개인키 (테스트용)
    uint256 public verifier1PrivateKey = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
    uint256 public verifier2PrivateKey = 0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890;

    uint256 public constant DAILY_REWARD = 1000 * 1e18; // 1000 KRW
    uint256 public constant TOTAL_BUDGET = 100000 * 1e18; // 100,000 KRW

    function setUp() public {
        // 개인키로부터 주소 생성
        verifier1 = vm.addr(verifier1PrivateKey);
        verifier2 = vm.addr(verifier2PrivateKey);

        protocol = new MissionProtocol(verifier1); // 기본 검증자로 verifier1 설정
        krw = new MockKRW();

        // 정부에게 초기 자금 제공
        krw.mint(government, 1000000 * 1e18); // 1,000,000 KRW
    }

    function testCreateMission() public {
        vm.startPrank(government);

        // KRW 승인
        krw.approve(address(protocol), TOTAL_BUDGET);

        // 승인된 검증기관 및 가맹점 배열 생성
        address[] memory verifiers = new address[](2);
        verifiers[0] = verifier1;
        verifiers[1] = verifier2;

        address[] memory merchants = new address[](2);
        merchants[0] = merchant1;
        merchants[1] = merchant2;

        // 미션 제안
        uint256 proposalId = protocol.createMissionProposal(
            "Health Walk Mission",
            "Daily walking mission for health",
            address(krw),
            TOTAL_BUDGET,
            20240101,
            20241231,
            verifiers,
            merchants,
            false // 전송 불가능
        );

        vm.stopPrank();
        // 오너가 승인 (address(this)에서 호출)
        uint256 missionId = protocol.approveMission(proposalId);

        vm.stopPrank();

        // 미션 정보 확인
        MissionProtocol.Mission memory mission = protocol.getMission(missionId);
        assertEq(mission.name, "Health Walk Mission");
        assertEq(mission.creator, government);
        assertEq(mission.totalBudget, TOTAL_BUDGET);
        assertEq(mission.spentBudget, 0);
        assertTrue(mission.status == MissionProtocol.MissionStatus.Active);

        // MissionToken이 올바르게 생성되었는지 확인
        MissionToken rewardToken = MissionToken(mission.rewardToken);
        assertEq(rewardToken.name(), "Mission-Health Walk Mission");
        assertEq(rewardToken.symbol(), "MHealth Walk Mission");
        assertEq(rewardToken.balanceOf(address(protocol)), TOTAL_BUDGET);

        // 가맹점 승인 확인
        assertTrue(rewardToken.authorizedMerchants(merchant1));
        assertTrue(rewardToken.authorizedMerchants(merchant2));
    }

    function testSubmitAttestation() public {
        // 먼저 미션 생성
        uint256 missionId = _createTestMission();

        // 현재 날짜 가져오기
        uint256 currentDate = protocol.getCurrentDate();
        bytes32 dataHash = keccak256("user1_walk_data_today");
        uint256 reward = DAILY_REWARD;

        // 실제 서명 생성
        bytes memory signature = _createSignature(user1, missionId, currentDate, dataHash, reward, verifier1PrivateKey);

        // 검증서 제출 (새로운 인터페이스 사용)
        protocol.submitAttestation(user1, missionId, currentDate, dataHash, reward, verifier1, signature);

        // 미션 정보 확인
        MissionProtocol.Mission memory mission = protocol.getMission(missionId);
        assertEq(mission.spentBudget, reward);

        // 사용자 참여 정보 확인
        MissionProtocol.UserParticipation memory participation = protocol.getUserParticipation(missionId, user1);

        assertEq(participation.totalRewardsEarned, reward);

        // 사용자가 토큰을 받았는지 확인
        MissionToken rewardToken = MissionToken(mission.rewardToken);
        assertEq(rewardToken.balanceOf(user1), reward);

        // 미션 수행 횟수 확인 (1회)
        uint256 completionCount = protocol.userMissionCompletions(missionId, user1);
        assertEq(completionCount, 1);

        // 같은 미션을 같은 날짜에 여러 번 수행해도 모두 인정됨
        bytes32 nextDataHash = keccak256("user1_walk_data_tomorrow");
        bytes memory nextSignature =
            _createSignature(user1, missionId, currentDate, nextDataHash, reward, verifier1PrivateKey);
        protocol.submitAttestation(user1, missionId, currentDate, nextDataHash, reward, verifier1, nextSignature);
        // 횟수는 2회로 증가
        assertEq(protocol.userMissionCompletions(missionId, user1), 2);
    }

    function testMerchantPayment() public {
        // 미션 생성 및 사용자 보상 지급
        uint256 missionId = _createTestMission();
        _giveUserReward(missionId, user1);

        MissionProtocol.Mission memory mission = protocol.getMission(missionId);
        MissionToken rewardToken = MissionToken(mission.rewardToken);

        uint256 paymentAmount = 500 * 1e18; // 500 KRW
        uint256 userInitialBalance = rewardToken.balanceOf(user1);
        uint256 merchantInitialKRW = krw.balanceOf(merchant1);

        // 사용자가 인증된 가맹점에게 직접 결제
        vm.prank(user1);
        rewardToken.payToMerchant(merchant1, paymentAmount);

        // 결과 확인
        assertEq(rewardToken.balanceOf(user1), userInitialBalance - paymentAmount);
        assertEq(krw.balanceOf(merchant1), merchantInitialKRW + paymentAmount);
    }

    function test_RevertWhen_UnauthorizedVerifier() public {
        uint256 missionId = _createTestMission();

        address unauthorizedVerifier = makeAddr("unauthorized");
        uint256 currentDate = protocol.getCurrentDate();
        bytes32 dataHash = keccak256("user1_walk_data_today");
        uint256 reward = DAILY_REWARD;

        // 잘못된 검증자로 서명해도 상관없음 (어차피 검증자 주소 체크에서 실패)
        bytes memory signature = _createSignature(user1, missionId, currentDate, dataHash, reward, verifier1PrivateKey);

        // 실패해야 함
        vm.expectRevert(MissionProtocol.UnauthorizedVerifier.selector);
        protocol.submitAttestation(
            user1,
            missionId,
            currentDate,
            dataHash,
            reward,
            unauthorizedVerifier, // 승인되지 않은 검증기관
            signature
        );
    }

    function test_RevertWhen_UnauthorizedMerchant() public {
        uint256 missionId = _createTestMission();
        _giveUserReward(missionId, user1);

        MissionProtocol.Mission memory mission = protocol.getMission(missionId);
        MissionToken rewardToken = MissionToken(mission.rewardToken);

        address unauthorizedMerchant = makeAddr("unauthorized_merchant");
        uint256 paymentAmount = 500 * 1e18;

        // 사용자가 인증되지 않은 가맹점에게 결제 시도 - 실패해야 함
        vm.expectRevert(MissionToken.NotAuthorizedMerchant.selector);
        vm.prank(user1);
        rewardToken.payToMerchant(unauthorizedMerchant, paymentAmount);
    }

    function testSubmitBatchAttestation() public {
        uint256 missionId = _createTestMission();
        uint256 currentDate = protocol.getCurrentDate();

        // 여러 사용자 배열 생성
        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = makeAddr("user3");

        bytes32[] memory dataHashes = new bytes32[](3);
        dataHashes[0] = keccak256("user1_walk_data");
        dataHashes[1] = keccak256("user2_walk_data");
        dataHashes[2] = keccak256("user3_walk_data");

        // 각 사용자별로 다른 보상 설정 (퀘스트 완성도에 따라)
        uint256[] memory rewards = new uint256[](3);
        rewards[0] = 800 * 1e18; // user1: 걷기 퀘스트 80% 완성
        rewards[1] = 1200 * 1e18; // user2: 걷기 + 추가 퀘스트 완성
        rewards[2] = 500 * 1e18; // user3: 걷기 퀘스트 50% 완성

        // 실제 배치 서명 생성
        bytes memory signature =
            _createBatchSignature(users, missionId, currentDate, dataHashes, rewards, verifier1PrivateKey);

        // 배치 검증서 생성
        MissionProtocol.BatchAttestation memory batchAttestation = MissionProtocol.BatchAttestation({
            users: users,
            missionId: missionId,
            date: currentDate,
            dataHashes: dataHashes,
            rewards: rewards,
            verifier: verifier1,
            signature: signature
        });

        // 배치 검증서 제출
        protocol.submitBatchAttestation(batchAttestation);

        // 미션 정보 확인 (각자 다른 보상이 지급되었는지)
        MissionProtocol.Mission memory mission = protocol.getMission(missionId);
        uint256 expectedTotal = rewards[0] + rewards[1] + rewards[2];
        assertEq(mission.spentBudget, expectedTotal);

        // 각 사용자의 참여 정보 확인
        for (uint256 i = 0; i < users.length; i++) {
            MissionProtocol.UserParticipation memory participation = protocol.getUserParticipation(missionId, users[i]);

            assertEq(participation.totalRewardsEarned, rewards[i]);

            // 사용자가 각자 다른 보상을 받았는지 확인
            MissionToken rewardToken = MissionToken(mission.rewardToken);
            assertEq(rewardToken.balanceOf(users[i]), rewards[i]);

            // 미션 수행 횟수도 1회로 기록되어야 함
            assertEq(protocol.userMissionCompletions(missionId, users[i]), 1);
        }
    }

    function testBatchAttestationWithZeroRewards() public {
        uint256 missionId = _createTestMission();
        uint256 currentDate = protocol.getCurrentDate();

        // 일부 사용자는 보상 0 (퀘스트 미완성)
        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = makeAddr("user3");

        bytes32[] memory dataHashes = new bytes32[](3);
        dataHashes[0] = keccak256("user1_walk_data");
        dataHashes[1] = keccak256("user2_walk_data");
        dataHashes[2] = keccak256("user3_walk_data");

        uint256[] memory rewards = new uint256[](3);
        rewards[0] = 1000 * 1e18; // user1: 완성
        rewards[1] = 0; // user2: 미완성 (0 보상)
        rewards[2] = 750 * 1e18; // user3: 부분 완성

        bytes memory signature =
            _createBatchSignature(users, missionId, currentDate, dataHashes, rewards, verifier1PrivateKey);

        MissionProtocol.BatchAttestation memory batchAttestation = MissionProtocol.BatchAttestation({
            users: users,
            missionId: missionId,
            date: currentDate,
            dataHashes: dataHashes,
            rewards: rewards,
            verifier: verifier1,
            signature: signature
        });

        protocol.submitBatchAttestation(batchAttestation);

        // 결과 확인
        MissionProtocol.Mission memory mission = protocol.getMission(missionId);
        assertEq(mission.spentBudget, 1000 * 1e18 + 750 * 1e18); // 0 보상은 제외

        MissionToken rewardToken = MissionToken(mission.rewardToken);
        assertEq(rewardToken.balanceOf(user1), 1000 * 1e18);
        assertEq(rewardToken.balanceOf(user2), 0); // 보상 없음
        assertEq(rewardToken.balanceOf(users[2]), 750 * 1e18);
    }

    function testBatchAttestationArrayMismatch() public {
        uint256 missionId = _createTestMission();
        uint256 currentDate = protocol.getCurrentDate();

        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;

        bytes32[] memory dataHashes = new bytes32[](2);
        dataHashes[0] = keccak256("user1_data");
        dataHashes[1] = keccak256("user2_data");

        // 배열 길이가 맞지 않음
        uint256[] memory rewards = new uint256[](3); // 사용자는 2명인데 보상은 3개
        rewards[0] = 1000 * 1e18;
        rewards[1] = 1000 * 1e18;
        rewards[2] = 1000 * 1e18;

        bytes memory signature =
            _createBatchSignature(users, missionId, currentDate, dataHashes, rewards, verifier1PrivateKey);

        MissionProtocol.BatchAttestation memory batchAttestation = MissionProtocol.BatchAttestation({
            users: users,
            missionId: missionId,
            date: currentDate,
            dataHashes: dataHashes,
            rewards: rewards,
            verifier: verifier1,
            signature: signature
        });

        // 배열 길이 불일치로 실패해야 함
        vm.expectRevert(MissionProtocol.ArrayLengthMismatch.selector);
        protocol.submitBatchAttestation(batchAttestation);
    }

    function testAddMissionBudget() public {
        uint256 missionId = _createTestMission();
        uint256 additionalBudget = 50000 * 1e18; // 50,000 KRW 추가

        // 정부에게 추가 자금 제공
        krw.mint(government, additionalBudget);

        vm.startPrank(government);
        krw.approve(address(protocol), additionalBudget);

        // 예산 추가 전 상태 확인
        MissionProtocol.Mission memory missionBefore = protocol.getMission(missionId);
        uint256 oldTotalBudget = missionBefore.totalBudget;

        // 예산 추가
        protocol.addMissionBudget(missionId, additionalBudget);
        vm.stopPrank();

        // 예산 추가 후 상태 확인
        MissionProtocol.Mission memory missionAfter = protocol.getMission(missionId);
        assertEq(missionAfter.totalBudget, oldTotalBudget + additionalBudget);

        // MissionToken도 증가했는지 확인
        MissionToken rewardToken = MissionToken(missionAfter.rewardToken);
        assertEq(rewardToken.balanceOf(address(protocol)), oldTotalBudget + additionalBudget);
    }

    function testUpdateMissionEndDate() public {
        uint256 missionId = _createTestMission();
        uint256 newEndDate = 20251231; // 2025년 12월 31일로 연장

        vm.prank(government);
        protocol.updateMissionEndDate(missionId, newEndDate);

        MissionProtocol.Mission memory mission = protocol.getMission(missionId);
        assertEq(mission.endDate, newEndDate);
    }

    function test_RevertWhen_NonCreatorAddsBudget() public {
        uint256 missionId = _createTestMission();
        uint256 additionalBudget = 10000 * 1e18;

        address nonCreator = makeAddr("nonCreator");
        krw.mint(nonCreator, additionalBudget);

        vm.startPrank(nonCreator);
        krw.approve(address(protocol), additionalBudget);

        vm.expectRevert(MissionProtocol.NotMissionCreator.selector);
        protocol.addMissionBudget(missionId, additionalBudget);
        vm.stopPrank();
    }

    function test_RevertWhen_NonCreatorUpdatesEndDate() public {
        uint256 missionId = _createTestMission();
        uint256 newEndDate = 20251231;

        address nonCreator = makeAddr("nonCreator");

        vm.expectRevert(MissionProtocol.NotMissionCreator.selector);
        vm.prank(nonCreator);
        protocol.updateMissionEndDate(missionId, newEndDate);
    }

    // 헬퍼 함수들
    function _createTestMission() internal returns (uint256) {
        vm.startPrank(government);

        krw.approve(address(protocol), TOTAL_BUDGET);

        address[] memory verifiers = new address[](2);
        verifiers[0] = verifier1;
        verifiers[1] = verifier2;

        address[] memory merchants = new address[](2);
        merchants[0] = merchant1;
        merchants[1] = merchant2;

        // 미션 제안
        uint256 proposalId = protocol.createMissionProposal(
            "Test Mission",
            "Test Description",
            address(krw),
            TOTAL_BUDGET,
            20240101,
            20241231,
            verifiers,
            merchants,
            false
        );

        vm.stopPrank();
        // 오너가 승인 (address(this)에서 호출)
        uint256 missionId = protocol.approveMission(proposalId);
        return missionId;
    }

    function _createSignature(
        address user,
        uint256 missionId,
        uint256 date,
        bytes32 dataHash,
        uint256 reward,
        uint256 privateKey
    ) internal pure returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encodePacked(user, missionId, date, dataHash, reward));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedMessageHash);
        return abi.encodePacked(r, s, v);
    }

    function _createBatchSignature(
        address[] memory users,
        uint256 missionId,
        uint256 date,
        bytes32[] memory dataHashes,
        uint256[] memory rewards,
        uint256 privateKey
    ) internal pure returns (bytes memory) {
        bytes32 batchMessageHash = keccak256(abi.encode(users, missionId, date, dataHashes, rewards));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(batchMessageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedMessageHash);
        return abi.encodePacked(r, s, v);
    }

    function _giveUserReward(uint256 missionId, address user) internal {
        uint256 currentDate = protocol.getCurrentDate();
        bytes32 dataHash = keccak256(abi.encodePacked(user, "_walk_data_today"));
        uint256 reward = DAILY_REWARD; // 기본 보상 사용
        bytes memory signature = _createSignature(user, missionId, currentDate, dataHash, reward, verifier1PrivateKey);

        protocol.submitAttestation(user, missionId, currentDate, dataHash, reward, verifier1, signature);
    }
}
