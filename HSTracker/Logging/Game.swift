/*
* This file is part of the HSTracker package.
* (c) Benjamin Michotte <bmichotte@gmail.com>
*
* For the full copyright and license information, please view the LICENSE
* file that was distributed with this source code.
*
* Created on 13/02/16.
*/

import Foundation
import RealmSwift
import HearthMirror

struct PlayingDeck {
    let id: String
    let name: String
    let hsDeckId: Int64?
    let playerClass: CardClass
    let heroId: String
    let cards: [Card]
    let isArena: Bool
}

class BoardSnapshot {
    let entities: [Entity]
    let turn: Int
    var techLevel = [ 0, 0, 0, 0, 0, 0 ]
    var triples = [ 0, 0, 0, 0, 0, 0 ]
    
    init(entities: [Entity], turn: Int) {
        self.entities = entities
        self.turn = turn
    }
}

/**
 * Game object represents the current state of the tracker
 */
class Game: NSObject, PowerEventHandler {

	/**
	 * View controller of this game object
	 */
    internal let windowManager = WindowManager()
	
    static let guiUpdateDelay: TimeInterval = 0.5
	
	private let turnTimer: TurnTimer
    
    fileprivate var lastKnownBattlegroundsBoardState = [String: BoardSnapshot]()
    
    private static let _lastKnownBoardStateLookup = [ CardIds.NonCollectible.Neutral.ArannaStarseeker_ArannaUnleashedTokenTavernBrawl: CardIds.NonCollectible.Neutral.ArannaStarseekerTavernBrawl1 ]
    
	private var hearthstoneRunState: HearthstoneRunState {
		didSet {
			if hearthstoneRunState.isRunning {
				// delay update as game might not have a proper window
				DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(1), execute: { [weak self] in
					self?.updateTrackers()
				})
			} else {
				self.updateTrackers()
			}
		}
	}
    private var selfAppActive: Bool = true
	
    func setHearthstoneRunning(flag: Bool) {
        hearthstoneRunState.isRunning = flag
    }
    
    func setHearthstoneActived(flag: Bool) {
        hearthstoneRunState.isActive = flag
    }
	
	func setSelfActivated(flag: Bool) {
		self.selfAppActive = flag
        self.updateTrackers()
	}
    
    func getCorrectBoardstateHeroId(heroId: String) -> String {
        if let mapped = Game._lastKnownBoardStateLookup[heroId] {
            return mapped
        }
        return heroId
    }
    
    func getSnapshot(opponentHeroCardId: String) -> BoardSnapshot? {
        if let state = lastKnownBattlegroundsBoardState[getCorrectBoardstateHeroId(heroId: opponentHeroCardId)] {
            return state
        }
        return nil
    }
    
    func snapshotBattlegroundsBoardState() {
        let opponentH = entities.values.first(where: { x in x.isHero && x.isInZone(zone: .play) && x.isControlled(by: opponent.id)})
        
        guard let opponentHero = opponentH else {
            return
        }

        // swiftlint:disable force_cast
        let entities = self.entities.values.filter({ x in x.isMinion && x.isInZone(zone: .play) && x.isControlled(by: opponent.id)}).map({ x in x.copy() as! Entity }).sorted(by: { x, y in
            x[.zone_position] < y[.zone_position]
        })
        // swiftlint:enable force_cast
        let correctedHero = getCorrectBoardstateHeroId(heroId: opponentHero.cardId)

        logger.info("Snapshotting board state for \(opponentHero.card.name) with cardid \(opponentHero.cardId) (corrected=\(correctedHero)) with \(entities.count) entities")
        let current = lastKnownBattlegroundsBoardState[correctedHero]
        let board = BoardSnapshot(entities: entities, turn: turnNumber())
        if let current = current {
            board.triples = current.triples
            board.techLevel = current.techLevel
        }
        lastKnownBattlegroundsBoardState[correctedHero] = board
        // pre-cache art
        DispatchQueue.global().async {
            for entity in board.entities {
                if ImageUtils.cachedArt(cardId: entity.cardId) == nil {
                    ImageUtils.art(for: entity.cardId, completion: { _ in
                        // nothing to do in the completion as we are only pre-caching it
                    })
                }
            }
        }
    }
	
	// MARK: - PowerEventHandler protocol
	
	func handleEntitiesChange(changed: [(old: Entity, new: Entity)]) {

        if let playerPair = changed.first(where: { $0.old.id == self.player.id }) {
			// TODO: player entity changed
			if let oldName = playerPair.old.name, let newName = playerPair.new.name, oldName != newName {
				print("Player entity name changed from \(oldName) to \(newName)")
			} else {
                // get added/removed tags
                let newTags = playerPair.new.tags.keys.filter { !playerPair.old.tags.keys.contains($0) }
                
                if newTags.contains(.mulligan_state) {
                    print("Player new mulligan state: \(playerPair.new[.mulligan_state])")
                }
			}
		}
	}
	
	func add(entity: Entity) {
		if entities[entity.id] == .none {
			entities[entity.id] = entity
		}
	}
	
	func determinedPlayers() -> Bool {
        return player.id > 0 && opponent.id > 0
	}
	
	private var guiNeedsUpdate = false
	private var guiUpdateResets = false
	private let _queue = DispatchQueue(label: "net.hearthsim.hstracker.guiupdate", attributes: [])
	
    private func updateAllTrackers() {
		SizeHelper.hearthstoneWindow.reload()
		
		self.updatePlayerTracker(reset: guiUpdateResets)
		self.updateOpponentTracker(reset: guiUpdateResets)
        self.updateCardHud()
        self.updateTurnTimer()
        self.updateBoardStateTrackers()
		self.updateArenaHelper()
        self.updateSecretTracker()
        self.updateBattlegroundsOverlay()
        self.updateBattlegroundsTierOverlay(reset: guiUpdateResets)
        self.updateBobsBuddyOverlay()
        self.updateTurnCounterOverlay()
        self.updateToaster()
        self.updateExperienceOverlay()
	}
	
    // MARK: - GUI calls
    var shouldShowGUIElement: Bool {
        return
            // do not show gui while spectating
            !(Settings.dontTrackWhileSpectating && self.spectator) &&
                // do not show gui while game is in background
                !((Settings.hideAllWhenGameInBackground || Settings.hideAllWhenGameInBackground) && !self.hearthstoneRunState.isActive)
    }
    
    func updateTrackers(reset: Bool = false) {
        _queue.async {
            self.guiNeedsUpdate = true
            self.guiUpdateResets = reset || self.guiUpdateResets
        }
    }
	
	@objc fileprivate func updateOpponentTracker(reset: Bool = false) {
		DispatchQueue.main.async { [unowned(unsafe) self] in
			
			let tracker = self.windowManager.opponentTracker
			if Settings.showOpponentTracker &&
                self.currentGameType != .gt_battlegrounds &&
            !(Settings.dontTrackWhileSpectating && self.spectator) &&
				((Settings.hideAllTrackersWhenNotInGame && !self.gameEnded)
					|| (!Settings.hideAllTrackersWhenNotInGame) || self.selfAppActive ) &&
				((Settings.hideAllWhenGameInBackground &&
					self.hearthstoneRunState.isActive) || !Settings.hideAllWhenGameInBackground || self.selfAppActive) {
				
				// update cards
                if self.gameEnded && Settings.clearTrackersOnGameEnd {
                    tracker.update(cards: [], reset: reset)
                } else {
                    tracker.update(cards: self.opponent.opponentCardList, reset: reset)
                }
				
				let gameStarted = !self.isInMenu && self.entities.count >= 67
				tracker.updateCardCounter(deckCount: !gameStarted ? 30 : self.opponent.deckCount,
				                          handCount: !gameStarted ? 0 : self.opponent.handCount,
				                          hasCoin: self.opponent.hasCoin,
				                          gameStarted: gameStarted)

				tracker.showCthunCounter = self.showOpponentCthunCounter
				tracker.showSpellCounter = Settings.showOpponentSpell
				tracker.showDeathrattleCounter = Settings.showOpponentDeathrattle
				tracker.showGraveyard = Settings.showOpponentGraveyard
				tracker.showJadeCounter = self.showOpponentJadeCounter
				tracker.proxy = self.opponentCthunProxy
				tracker.nextJadeSize = self.opponentNextJadeGolem
				tracker.fatigueCounter = self.opponent.fatigue
				tracker.spellsPlayedCount = self.opponent.spellsPlayedCount
				tracker.deathrattlesPlayedCount = self.opponent.deathrattlesPlayedCount
                tracker.showLibramCounter = Settings.showOpponentLibramCounter
                tracker.libramReductionCount = self.opponent.libramReductionCount
                
                if let opponentEntity = self.opponentEntity {
                    tracker.galakrondInvokeCounter = opponentEntity.has(tag: GameTag.invoke_counter) ? opponentEntity[GameTag.invoke_counter] : 0
                }
				
                if let fullname = self.opponent.name {
                    let names = fullname.components(separatedBy: "#")
                    tracker.playerName = names[0]
                }
				
                tracker.graveyard = self.opponent.graveyard
				tracker.playerClassId = self.opponent.playerClassId
				
				tracker.currentFormat = self.currentFormat
				tracker.currentGameMode = self.currentGameMode
				tracker.matchInfo = self.matchInfo
				
				tracker.setWindowSizes()
				var rect: NSRect?
				
				if Settings.autoPositionTrackers && self.hearthstoneRunState.isRunning {
					rect = SizeHelper.opponentTrackerFrame()
				} else {
					rect = Settings.opponentTrackerFrame
					if rect == nil {
						let x = WindowManager.screenFrame.origin.x + 50
						rect = NSRect(x: x,
						              y: WindowManager.top + WindowManager.screenFrame.origin.y,
						              width: WindowManager.cardWidth,
						              height: WindowManager.top)
					}
				}
				tracker.hasValidFrame = true
                self.windowManager.show(controller: tracker, show: true,
                                        frame: rect, title: "Opponent tracker",
                                        overlay: self.hearthstoneRunState.isActive)
			} else {
				self.windowManager.show(controller: tracker, show: false)
			}
		}
	}

    @objc fileprivate func updatePlayerTracker(reset: Bool = false) {
        DispatchQueue.main.async { [unowned(unsafe) self] in
			
            let tracker = self.windowManager.playerTracker
            if Settings.showPlayerTracker &&
                !(Settings.dontTrackWhileSpectating && self.spectator) &&
                (self.currentGameType != .gt_battlegrounds) &&
                ( (Settings.hideAllTrackersWhenNotInGame && !self.gameEnded)
                    || (!Settings.hideAllTrackersWhenNotInGame) || self.selfAppActive ) &&
                ((Settings.hideAllWhenGameInBackground &&
                    self.hearthstoneRunState.isActive) || !Settings.hideAllWhenGameInBackground || self.selfAppActive) {
                
                // update cards
                tracker.update(cards: self.player.playerCardList, reset: reset)
                
                // update card counter values
                let gameStarted = !self.isInMenu && self.entities.count >= 67
                tracker.updateCardCounter(deckCount: !gameStarted ? 30 : self.player.deckCount,
                                          handCount: !gameStarted ? 0 : self.player.handCount,
                                          hasCoin: self.player.hasCoin,
                                          gameStarted: gameStarted)
                
                tracker.showCthunCounter = self.showPlayerCthunCounter
                tracker.showSpellCounter = Settings.showPlayerSpell
                tracker.showDeathrattleCounter = self.showPlayerDeathrattleCounter
                tracker.showGraveyard = Settings.showPlayerGraveyard
                tracker.showJadeCounter = self.showPlayerJadeCounter
                tracker.proxy = self.playerCthunProxy
                tracker.nextJadeSize = self.playerNextJadeGolem
                tracker.fatigueCounter = self.player.fatigue
                tracker.spellsPlayedCount = self.player.spellsPlayedCount
                tracker.deathrattlesPlayedCount = self.player.deathrattlesPlayedCount
                tracker.showLibramCounter = Settings.showPlayerLibramCounter
                tracker.libramReductionCount = self.player.libramReductionCount
                
                if let playerEntity = self.playerEntity {
                    tracker.hasGalakrondProxy = playerEntity.has(tag: GameTag.proxy_galakrond)
                    tracker.galakrondInvokeCounter = playerEntity.has(tag: GameTag.invoke_counter) ? playerEntity[GameTag.invoke_counter] : 0
                }
                
                if let currentDeck = self.currentDeck {
                    if let deck = RealmHelper.getDeck(with: currentDeck.id) {
                        tracker.recordTrackerMessage = StatsHelper
                            .getDeckManagerRecordLabel(deck: deck,
                                                       mode: .all)
                    }
                    tracker.playerName = currentDeck.name
                    if !currentDeck.heroId.isEmpty {
                        tracker.playerClassId = currentDeck.heroId
                    } else {
                        tracker.playerClassId = currentDeck.playerClass.defaultHeroCardId
                    }
                } else {
                    tracker.playerName = player.name
                    tracker.playerClassId = playerHeroId
                }
                
                tracker.graveyard = self.player.graveyard
                
                tracker.currentFormat = self.currentFormat
                tracker.currentGameMode = self.currentGameMode
                tracker.matchInfo = self.matchInfo
                
                tracker.setWindowSizes()
                
                var rect: NSRect?
                
                if Settings.autoPositionTrackers && self.hearthstoneRunState.isRunning {
                    rect = SizeHelper.playerTrackerFrame()
                } else {
                    rect = Settings.playerTrackerFrame
                    if rect == nil {
                        let x = WindowManager.screenFrame.width - WindowManager.cardWidth
                            + WindowManager.screenFrame.origin.x
                        rect = NSRect(x: x,
                                      y: WindowManager.top + WindowManager.screenFrame.origin.y,
                                      width: WindowManager.cardWidth,
                                      height: WindowManager.top)
                    }
                }
                tracker.hasValidFrame = true
                self.windowManager.show(controller: tracker, show: true,
                                   frame: rect, title: "Player tracker",
                                   overlay: self.hearthstoneRunState.isActive)
            } else {
                self.windowManager.show(controller: tracker, show: false)
            }
        }
    }
    
    func updateTurnCounter(turn: Int) {
        DispatchQueue.main.async { [unowned(unsafe) self] in
            self.windowManager.turnCounter.setTurnNumber(turn: turn)

            let isBG = self.isBattlegroundsMatch() && !self.gameEnded

            if isBG && Settings.showTurnCounter && ((Settings.hideAllWhenGameInBackground && self.hearthstoneRunState.isActive) || !Settings.hideAllWhenGameInBackground) {
                let rect = SizeHelper.turnCounterFrame()
                self.windowManager.show(controller: self.windowManager.turnCounter, show: true, frame: rect, title: nil, overlay: self.hearthstoneRunState.isActive)
            } else {
                self.windowManager.show(controller: self.windowManager.turnCounter, show: false)
            }
        }
    }

    func updateTurnTimer() {
        DispatchQueue.main.async { [unowned(unsafe) self] in

            if Settings.showTimer && !self.gameEnded && self.shouldShowGUIElement && !isBattlegroundsMatch() {
                var rect: NSRect?
                if Settings.autoPositionTrackers {
                    rect = SizeHelper.timerHudFrame()
                } else {
                    rect = Settings.timerHudFrame
                    if rect == nil {
                        rect = SizeHelper.timerHudFrame()
                    }
                }
                if let timerHud = self.turnTimer.timerHud {
                    timerHud.hasValidFrame = true
                    self.windowManager.show(controller: timerHud, show: true, frame: rect, title: nil, overlay: self.hearthstoneRunState.isActive)
                }
            } else {
                if let timerHud = self.turnTimer.timerHud {
                    self.windowManager.show(controller: timerHud, show: false)
                }
            }
            
        }
    }
    
    func updateSecretTracker(cards: [Card]) {
        self.windowManager.secretTracker.set(cards: cards)
        self.updateSecretTracker()
    }
    
    func updateSecretTracker() {
        DispatchQueue.main.async { [unowned(unsafe) self] in
            
            let tracker = self.windowManager.secretTracker
            
            if Settings.showSecretHelper && !self.gameEnded &&
                ((Settings.hideAllWhenGameInBackground && self.hearthstoneRunState.isActive)
                    || !Settings.hideAllWhenGameInBackground) && !isBattlegroundsMatch() {
                if tracker.cardCount() > 0 {
                    tracker.setWindowSizes()
                    let rect = SizeHelper.secretTrackerFrame(height: tracker.frameHeight)
                    tracker.contentViewController?.preferredContentSize = rect.size
                    self.windowManager.show(controller: tracker, show: true,
                                            frame: rect,
                                            title: nil, overlay: self.hearthstoneRunState.isActive)
                } else {
                    self.windowManager.show(controller: tracker, show: false)
                }
            } else {
                self.windowManager.show(controller: tracker, show: false)
            }
        }
    }
    
    func updateBattlegroundsOverlay() {
        let rect = SizeHelper.battlegroundsOverlayFrame()

        DispatchQueue.main.async {
            let isBG = self.isBattlegroundsMatch() && !self.gameEnded

            if isBG && ((Settings.hideAllWhenGameInBackground && self.hearthstoneRunState.isActive)
                    || !Settings.hideAllWhenGameInBackground) {
                
                self.windowManager.show(controller: self.windowManager.battlegroundsOverlay, show: true, frame: rect, title: nil, overlay: true)
            } else {
                self.windowManager.show(controller: self.windowManager.battlegroundsOverlay, show: false)
            }
        }
    }
    
    func updateToaster() {
        let rect = SizeHelper.toastFrame()

        DispatchQueue.main.async {
            if self.windowManager.toastWindowController.displayed {
                self.windowManager.show(controller: self.windowManager.toastWindowController, show: true, frame: rect, title: nil, overlay: true)
            } else {
                self.windowManager.show(controller: self.windowManager.toastWindowController, show: false)
            }
        }

    }
    
    func updateTurnCounterOverlay() {
        let rect = SizeHelper.turnCounterFrame()
        
        DispatchQueue.main.async {
            let isBG = self.isBattlegroundsMatch() && !self.gameEnded
            if isBG && Settings.showTurnCounter &&
                ((Settings.hideAllWhenGameInBackground && self.hearthstoneRunState.isActive)
                || !Settings.hideAllWhenGameInBackground) {
                self.windowManager.show(controller: self.windowManager.turnCounter, show: true, frame: rect, title: nil, overlay: true)
            } else {
                self.windowManager.show(controller: self.windowManager.turnCounter, show: false)
            }
        }
    }

    func updateBobsBuddyOverlay() {
        let rect = SizeHelper.bobsPanelOverlayFrame()
        
        DispatchQueue.main.async {
            let isBG = self.isBattlegroundsMatch() && !self.gameEnded
            if isBG && Settings.showBobsBuddy &&
                ((Settings.hideAllWhenGameInBackground && self.hearthstoneRunState.isActive)
                    || !Settings.hideAllWhenGameInBackground) && !self.hideBobsBuddy {
                self.windowManager.show(controller: self.windowManager.bobsBuddyPanel, show: true, frame: rect, title: nil, overlay: true)
            } else {
                self.windowManager.show(controller: self.windowManager.bobsBuddyPanel, show: false)
            }
        }
    }
    
    func updateBattlegroundsTierOverlay(reset: Bool) {
        let rect = SizeHelper.battlegroundsTierOverlayFrame()
                
        DispatchQueue.main.async {
            let isBG = self.isBattlegroundsMatch() && !self.gameEnded

            let controller = self.windowManager.battlegroundsTierOverlay

            if isBG && Settings.showTiers && ((Settings.hideAllWhenGameInBackground && self.hearthstoneRunState.isActive)
                    || !Settings.hideAllWhenGameInBackground) {
                self.windowManager.show(controller: controller, show: true, frame: rect, title: nil, overlay: true)
                controller.tierOverlay.unhideTier()
                if reset {
                    controller.tierOverlay.displayTier(tier: controller.tierOverlay.currentTier, force: true)
                }
            } else {
                self.windowManager.show(controller: controller, show: false)
                controller.tierOverlay.hideTier()
            }
        }
    }
    
    func updateExperienceOverlay() {
        let rect = SizeHelper.experienceOverlayFrame()
        
        DispatchQueue.main.async {
            let experiencePanel = self.windowManager.experiencePanel
            if Settings.showExperienceCounter && experiencePanel.visible && ((Settings.hideAllWhenGameInBackground && self.hearthstoneRunState.isActive) || !Settings.hideAllWhenGameInBackground) {
                self.windowManager.show(controller: experiencePanel, show: true, frame: rect, title: nil, overlay: true)
            } else {
                self.windowManager.show(controller: experiencePanel, show: false)
            }
        }
    }
    
    static let experienceFadeDelay = 6.0
    
    func experienceChangedAsync(experience: Int, experienceNeeded: Int, level: Int, levelChange: Int, animate: Bool) {
        let currentMode = self.currentMode ?? .invalid
        let previousMode = self.previousMode ?? .invalid
        
        logger.debug("Experience changed. Current mode \(currentMode), previous \(previousMode)")
        
        while let cm = self.currentMode, let pm = self.previousMode, cm == Mode.gameplay && pm == Mode.bacon {
            Thread.sleep(forTimeInterval: 0.500)
        }
        logger.debug("Showing experience counter now")
        let experienceCounter = windowManager.experiencePanel.experienceTracker
        experienceCounter.xpDisplay = "\(experience)/\(experienceNeeded)"
        experienceCounter.levelDisplay = "\(level+1)"
        experienceCounter.xpPercentage = (Double(experience) / Double(experienceNeeded))
        if animate {
            DispatchQueue.main.async {
                experienceCounter.needsDisplay = true
                self.windowManager.experiencePanel.visible = true
                self.updateExperienceOverlay()
                self.guiNeedsUpdate = true
            }
            Thread.sleep(forTimeInterval: Game.experienceFadeDelay)
        } else {
            DispatchQueue.main.async {
                experienceCounter.needsDisplay = true
                
            }
        }
        if currentMode != Mode.hub {
            windowManager.experiencePanel.visible = false
            guiNeedsUpdate = true
        }
    }

    func updateCardHud() {
        tryToDetectWhizbangDeck()

        DispatchQueue.main.async { [unowned(unsafe) self] in
            
            let tracker = self.windowManager.cardHudContainer
            
            if Settings.showCardHuds && self.shouldShowGUIElement {
                if !self.gameEnded {
                    tracker.update(entities: self.opponent.hand,
                                            cardCount: self.opponent.handCount)
                    self.windowManager.show(controller: tracker, show: true,
                         frame: SizeHelper.cardHudContainerFrame(), title: nil,
                         overlay: self.hearthstoneRunState.isActive)
                } else {
                    self.windowManager.show(controller: tracker, show: false)
                }
            } else {
                self.windowManager.show(controller: tracker, show: false)
            }
        }
    }
    
    func updateBoardStateTrackers() {
        DispatchQueue.main.async {
            // board damage
            let board = BoardState(game: self)
            
            let playerBoardDamage = self.windowManager.playerBoardDamage
            let opponentBoardDamage = self.windowManager.opponentBoardDamage
            
            var rect: NSRect?
            
            if Settings.playerBoardDamage && self.shouldShowGUIElement && (self.currentGameType != .gt_battlegrounds) {
                if !self.gameEnded {
                    var heroPowerDmg = 0
                    if let heroPower = board.player.heroPower, self.player.currentMana >= heroPower.cost {
                        heroPowerDmg = heroPower.damage

                        // Garrison Commander = hero power * 2
                        if board.player.cards.first(where: { $0.cardId == "AT_080"}) != nil {
                            heroPowerDmg *= 2
                        }
                    }
                    playerBoardDamage.update(attack: board.player.damage + heroPowerDmg)
                    if Settings.autoPositionTrackers {
                        rect = SizeHelper.playerBoardDamageFrame()
                    } else {
                        rect = Settings.playerBoardDamageFrame
                        if rect == nil {
                            rect = SizeHelper.playerBoardDamageFrame()
                        }
                    }
                    playerBoardDamage.hasValidFrame = true
                    self.windowManager.show(controller: playerBoardDamage, show: true,
                         frame: rect, title: nil, overlay: self.hearthstoneRunState.isActive)
                } else {
                    self.windowManager.show(controller: playerBoardDamage, show: false)
                }
            } else {
                self.windowManager.show(controller: playerBoardDamage, show: false)
            }
            
            if Settings.opponentBoardDamage && self.shouldShowGUIElement && (self.currentGameType != .gt_battlegrounds) {
                if !self.gameEnded {
                    var heroPowerDmg = 0
                    if let heroPower = board.opponent.heroPower {
                        heroPowerDmg = heroPower.damage

                        // Garrison Commander = hero power * 2
                        if board.opponent.cards.first(where: { $0.cardId == "AT_080"}) != nil {
                            heroPowerDmg *= 2
                        }
                    }
                    opponentBoardDamage.update(attack: board.opponent.damage + heroPowerDmg)
                    if Settings.autoPositionTrackers {
                        rect = SizeHelper.opponentBoardDamageFrame()
                    } else {
                        rect = Settings.opponentBoardDamageFrame
                        if rect == nil {
                            rect = SizeHelper.opponentBoardDamageFrame()
                        }
                    }
                    opponentBoardDamage.hasValidFrame = true
                    self.windowManager.show(controller: opponentBoardDamage, show: true,
                         frame: SizeHelper.opponentBoardDamageFrame(), title: nil,
                         overlay: self.hearthstoneRunState.isActive)
                } else {
                    self.windowManager.show(controller: opponentBoardDamage, show: false)
                }
            } else {
                self.windowManager.show(controller: opponentBoardDamage, show: false)
            }
        }
    }
	
	func updateArenaHelper() {
		DispatchQueue.main.async {
			
			let tracker = self.windowManager.arenaHelper
			
			if Settings.showArenaHelper && ArenaWatcher.isRunning() &&
                !(Settings.dontTrackWhileSpectating && self.spectator) &&
				self.windowManager.arenaHelper.cardCount() == 3 &&
				((Settings.hideAllWhenGameInBackground && self.hearthstoneRunState.isActive)
					|| !Settings.hideAllWhenGameInBackground ) {
                tracker.setWindowSizes()
                self.windowManager.arenaHelper.table?.reloadData()
				self.windowManager.show(controller: tracker, show: true, frame: SizeHelper.arenaHelperFrame(),
                                        title: nil, overlay: self.hearthstoneRunState.isActive)
			} else {
				self.windowManager.show(controller: tracker, show: false)
			}
		}
	}
	
    // MARK: - Vars
    
    var buildNumber: Int = 0
    var playerIDNameMapping: [Int: String] = [:]
    
	var startTime: Date?
    var currentTurn = 0
    var lastId = 0
    var gameTriggerCount = 0
	private var playerDeckAutodetected: Bool = false
    private var hasValidDeck = false
    private var powerLog: [LogLine] = []
    func add(powerLog: LogLine) {
        self.powerLog.append(powerLog)
    }
    
    var playedCards: [PlayedCard] = []
    var proposedAttackerEntityId: Int = 0
    var proposedDefenderEntityId: Int = 0
	var player: Player!
    var opponent: Player!
    var currentMode: Mode? = .invalid
    var previousMode: Mode? = .invalid
    
    private var _brawlInfo: BrawlInfo?
	
	var gameResult: GameResult = .unknown
	var wasConceded: Bool = false

    private var _spectator: Bool?
    var spectator: Bool {
        if let spec = _spectator {
            return spec
        } else if MirrorHelper.isInitialized() {
            _spectator = MirrorHelper.isSpectating()
        }
        return _spectator ?? false
	}

    private var _currentGameMode: GameMode = .none
    var currentGameMode: GameMode {
        if spectator {
            return .spectator
        }

        if _currentGameMode == .none {
            _currentGameMode = GameMode(gameType: currentGameType)
        }
        return _currentGameMode
    }

    private var _currentGameType: GameType = .gt_unknown
    var currentGameType: GameType {

        if _currentGameType != .gt_unknown {
            return _currentGameType
        }
        if self.gameEnded {
            return .gt_unknown
        }
        if let gameType = MirrorHelper.getGameType(),
            let type = GameType(rawValue: gameType) {
            _currentGameType = type
        }
        return _currentGameType
    }
    
    private var _serverInfo: MirrorGameServerInfo?
    var serverInfo: MirrorGameServerInfo? {
        if _serverInfo == nil {
            _serverInfo = MirrorHelper.getGameServerInfo()
        }
        return _serverInfo
    }

	var entities: [Int: Entity] = [:] {
		didSet {
			// collect all elements that changed
			let newKeys = entities.keys
			
			let changedElements = Array(newKeys.filter {
				if let oldEntity = oldValue[$0] {
					return oldEntity != self.entities[$0]
				}
				return false
			}).map { (old: oldValue[$0]!, new: self.entities[$0]!) }
			self.handleEntitiesChange(changed: changedElements)
		}
	}
    var tmpEntities: [Entity] = []
    var knownCardIds: [Int: [String]] = [:]
    var joustReveals = 0

    var lastCardPlayed: Int?
    var gameEnded = true
    internal private(set) var currentDeck: PlayingDeck?

    var currentEntityHasCardId = false
    var playerUsedHeroPower = false
    private var hasCoin = false
    var currentEntityZone: Zone = .invalid
    var opponentUsedHeroPower = false
	var wasInProgress = false
    var setupDone = false
    var secretsManager: SecretsManager?
    var proposedAttacker = 0
    var proposedDefender = 0
    var isDungeonMatch: Bool = false
    private var defendingEntity: Entity?
    private var attackingEntity: Entity?
    private var avengeDeathRattleCount = 0
    private var awaitingAvenge = false
    var isInMenu = true
    private var handledGameEnd = false
    
	var enqueueTime = LogDate(date: Date.distantPast)
    private var lastTurnStart: [Int] = [0, 0]
    private var turnQueue: Set<PlayerTurn> = Set()
    
	fileprivate var lastGameStartTimestamp: LogDate = LogDate(date: Date.distantPast)

    private var _matchInfo: MatchInfo?
    
    private var _battlegroundsRating: Int?
    
    private var _availableRaces: [Race]?
    
    private var _unavailableRaces: [Race]?
    
    var adventureOpponentId: String?
    
    var hideBobsBuddy = false
    
    var availableRaces: [Race]? {
        if _availableRaces == nil {
            if let races = MirrorHelper.getAvailableBattlegroundsRaces() {
                let newRaces = races.compactMap({ x in x.intValue > 0 && x.intValue < Race.allCases.count ? Race.allCases[x.intValue] : nil })
                logger.info("Battlegrounds available races: \(newRaces) - from mirror \(races)")
                if newRaces.count == races.count {
                    _availableRaces = newRaces
                    return _availableRaces
                }
            }
        }
        return _availableRaces
    }
    
    var unavailableRaces: [Race]? {
        if _unavailableRaces == nil {
            if let races = MirrorHelper.getUnavailableBattlegroundsRaces() {
                let newRaces = races.compactMap({ x in x.intValue > 0 && x.intValue < Race.allCases.count ? Race.allCases[x.intValue] : nil })
                logger.info("Battlegrounds unavailable races: \(newRaces) - from mirror \(races)")
                if newRaces.count == races.count && newRaces.count == 3 {
                    _unavailableRaces = newRaces
                    return _unavailableRaces
                } else {
                    return nil
                }
            }
        }
        return _unavailableRaces
    }

    var battlegroundsRating: Int? {
        if let rating = _battlegroundsRating {
            return rating
        }
        
        _battlegroundsRating = MirrorHelper.getBattlegroundsRating()
        
        logger.debug("Got battlegroundsRating=\(_battlegroundsRating ?? -1)")
        return _battlegroundsRating
    }
    
    private func validateMedalInfo(medalInfo: MatchInfo.MedalInfo) -> Bool {
        if medalInfo.stars < 0 || medalInfo.stars > 1000 || medalInfo.starLevel < 0 || medalInfo.starLevel > 51 || medalInfo.starMultiplier < 0 || medalInfo.starMultiplier > 20 {
            return false
        }
        return true
    }
    
    var matchInfo: MatchInfo? {
        
        if _matchInfo != nil {
            return _matchInfo
        }
        
        if !self.gameEnded, let mInfo = MirrorHelper.getMatchInfo() {
            let matchInfo = MatchInfo(info: mInfo)
            logger.info("\(matchInfo.localPlayer.name)"
                + " vs \(matchInfo.opposingPlayer.name)"
                + " matchInfo: \(matchInfo)")
            
            if validateMedalInfo(medalInfo: matchInfo.localPlayer.standardMedalInfo) &&
                validateMedalInfo(medalInfo: matchInfo.localPlayer.wildMedalInfo) &&
                validateMedalInfo(medalInfo: matchInfo.localPlayer.classicMedalInfo) &&
                validateMedalInfo(medalInfo: matchInfo.opposingPlayer.standardMedalInfo) &&
                validateMedalInfo(medalInfo: matchInfo.opposingPlayer.wildMedalInfo) &&
                validateMedalInfo(medalInfo: matchInfo.opposingPlayer.classicMedalInfo) {
                // the player name is now read from the log file but the opponent is not
                self.player.name = matchInfo.localPlayer.name
                self.opponent.name = matchInfo.opposingPlayer.name
                self.player.id = matchInfo.localPlayer.playerId
                self.opponent.id = matchInfo.opposingPlayer.playerId
                self._currentGameType = matchInfo.gameType
                self.currentFormat = matchInfo.formatType

                let opponentStarLevel = matchInfo.opposingPlayer.standardMedalInfo.starLevel
                logger.info("LADDER opponentStarLevel=\(opponentStarLevel)")
                self._matchInfo = matchInfo
            } else {
                return nil
            }
            
            // request a mirror read so we have this data at the end of the game
            _ = self.serverInfo
        }
        
        return _matchInfo
    }
	
    var arenaInfo: ArenaInfo? {
        if let _arenaInfo = MirrorHelper.getArenaDeck() {
            return ArenaInfo(info: _arenaInfo)
        }
        return nil
    }

    var brawlInfo: BrawlInfo? {
        if let brawlInfo = _brawlInfo {
            return brawlInfo
        }
        if let _brawlInfo = MirrorHelper.getBrawlInfo() {
            return BrawlInfo(info: _brawlInfo)
        }
        return nil
    }

    var playerEntity: Entity? {
        return entities.map { $0.1 }.first { $0[.player_id] == self.player.id }
    }

    var opponentEntity: Entity? {
        return entities.map { $0.1 }.first { $0.has(tag: .player_id) && !$0.isPlayer(eventHandler: self) }
    }

    var gameEntity: Entity? {
        return entities.map { $0.1 }.first { $0.name == "GameEntity" }
    }

    var isMinionInPlay: Bool {
        return entities.map { $0.1 }.first { $0.isInPlay && $0.isMinion } != nil
    }

    var isOpponentMinionInPlay: Bool {
        return entities.map { $0.1 }
            .first { $0.isInPlay && $0.isMinion
                && $0.isControlled(by: self.opponent.id) } != nil
    }

    var opponentMinionCount: Int {
        return entities.map { $0.1 }
            .filter { $0.isInPlay && $0.isMinion
                && $0.isControlled(by: self.opponent.id) }.count }

    var playerMinionCount: Int {
        return entities.map { $0.1 }
            .filter { $0.isInPlay && $0.isMinion
                && $0.isControlled(by: self.player.id) }.count }

    var opponentHandCount: Int {
        return entities.map { $0.1 }
            .filter { $0.isInHand && $0.isControlled(by: self.opponent.id) }.count }
    
    var opponentSecretCount: Int {
        return entities.map { $0.1 }
            .filter { $0.isSecret && $0.isControlled(by: self.opponent.id) }.count
    }
    
    var inAiMatch: Bool {
        return currentMode == Mode.gameplay && currentGameType == GameType.gt_vs_ai
    }
    
    var inAdventureScreen: Bool {
        return currentMode == Mode.adventure
    }
    
    var inPVPDungeonRunScreen: Bool {
        return currentMode == Mode.pvp_dungeon_run
    }
    
    var inPVPDungeonRunMatch: Bool {
        return currentMode == Mode.gameplay && previousMode == Mode.pvp_dungeon_run
    }
    
    var playerHeroId: String {
        return player.board.first(where: { x in x.isHero })?.cardId ?? ""
    }

    var opponentHeroId: String {
        return opponent.board.first(where: { x in x.isHero })?.cardId ?? ""
    }
    
    var opponentHeroHealth: Int {
        return opponent.board.first(where: { x in x.isHero })?[.health] ?? 0
    }

    private(set) var currentFormat = Format(formatType: FormatType.ft_unknown)

	// MARK: - Lifecycle
    private var observers: [NSObjectProtocol] = []
    
    init(hearthstoneRunState: HearthstoneRunState) {
        self.hearthstoneRunState = hearthstoneRunState
		turnTimer = TurnTimer(gui: windowManager.timerHud)
        super.init()
		player = Player(local: true, game: self)
        opponent = Player(local: false, game: self)
        secretsManager = SecretsManager(game: self)
        secretsManager?.onChanged = { [weak self] cards in
            self?.updateSecretTracker(cards: cards)
        }
		
		windowManager.startManager()
        windowManager.playerTracker.window?.delegate = self
        windowManager.opponentTracker.window?.delegate = self
		
		let center = NotificationCenter.default
		
		// events that should update the player tracker
		let playerTrackerUpdateEvents = [Settings.show_player_tracker, Settings.rarity_colors, Settings.remove_cards_from_deck,
		                                 Settings.highlight_last_drawn, Settings.highlight_cards_in_hand, Settings.highlight_discarded,
		                                 Settings.show_player_get, Settings.player_draw_chance, Settings.player_card_count,
		                                 Settings.player_cthun_frame, Settings.player_yogg_frame, Settings.player_deathrattle_frame,
		                                 Settings.show_win_loss_ratio, Settings.player_in_hand_color, Settings.show_deck_name,
		                                 Settings.player_graveyard_details_frame, Settings.player_graveyard_frame]
		
		// events that should update the opponent's tracker
		let opponentTrackerUpdateEvents = [Settings.show_opponent_tracker, Settings.opponent_card_count, Settings.opponent_draw_chance,
		                                   Settings.opponent_cthun_frame, Settings.opponent_yogg_frame, Settings.opponent_deathrattle_frame,
		                                   Settings.show_opponent_class, Settings.opponent_graveyard_frame,
		                                   Settings.opponent_graveyard_details_frame]
		
		// events that should update all trackers
		let allTrackerUpdateEvents = [Settings.rarity_colors, Events.reload_decks, Settings.window_locked, Settings.auto_position_trackers,
		                              Events.space_changed, Events.hearthstone_closed, Events.hearthstone_running,
		                              Events.hearthstone_active, Events.hearthstone_deactived, Settings.can_join_fullscreen,
		                              Settings.hide_all_trackers_when_not_in_game, Settings.hide_all_trackers_when_game_in_background,
		                              Settings.card_size, Settings.theme_token]
        
        for option in playerTrackerUpdateEvents {
            let observer = center.addObserver(forName: NSNotification.Name(rawValue: option), object: nil, queue: OperationQueue.main) { _ in
                self.updatePlayerTracker()
            }
            self.observers.append(observer)
        }
        
        for option in opponentTrackerUpdateEvents {
            let observer = center.addObserver(forName: NSNotification.Name(rawValue: option), object: nil, queue: OperationQueue.main) { _ in
                self.updateOpponentTracker()
            }
            self.observers.append(observer)
        }
		
		for option in allTrackerUpdateEvents {
            let observer = center.addObserver(forName: NSNotification.Name(rawValue: option), object: nil, queue: OperationQueue.main) { _ in
                self.updateAllTrackers()
            }
            self.observers.append(observer)
		}
		
		// start gui updater thread
		_queue.async {
//			while true {
            self.internalUpdateCheck()
//				Thread.sleep(forTimeInterval: Game.guiUpdateDelay)
//			}
		}
    }
    
    deinit {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func internalUpdateCheck() {
        if self.guiNeedsUpdate {
            self.guiNeedsUpdate = false
            self.updateAllTrackers()
            self.guiUpdateResets = false
        }
        _queue.asyncAfter(deadline: DispatchTime.now() + Game.guiUpdateDelay, execute: {
            self.internalUpdateCheck()
        })
    }

    func reset() {
        logger.verbose("Reseting Game")
        currentTurn = 0
        hasValidDeck = false

        playedCards.removeAll()
		
		self.gameResult = .unknown
		self.wasConceded = false

        lastId = 0
        gameTriggerCount = 0

        _matchInfo = nil
        _battlegroundsRating = nil
        currentFormat = Format(formatType: FormatType.ft_unknown)
        _currentGameType = .gt_unknown
		_currentGameMode = .none
        _serverInfo = nil

        entities.removeAll()
        tmpEntities.removeAll()
        knownCardIds.removeAll()
        joustReveals = 0
		
        lastCardPlayed = nil
        
        currentEntityHasCardId = false
        playerUsedHeroPower = false
        hasCoin = false
        currentEntityZone = .invalid
        opponentUsedHeroPower = false
        setupDone = false
        secretsManager?.reset()
        proposedAttacker = 0
        proposedDefender = 0
        defendingEntity = nil
        attackingEntity = nil
        avengeDeathRattleCount = 0
        awaitingAvenge = false
        lastTurnStart = [0, 0]

        player.reset()
        if let currentdeck = self.currentDeck {
            player.playerClass = currentdeck.playerClass
        }
        opponent.reset()
        updateSecretTracker(cards: [])
        windowManager.hideGameTrackers()
        powerLog.removeAll()
		
		_spectator = nil
        _availableRaces = nil
        _unavailableRaces = nil
        _brawlInfo = nil
        lastKnownBattlegroundsBoardState.removeAll()
        windowManager.battlegroundsDetailsWindow.reset()
        windowManager.bobsBuddyPanel.resetDisplays()
        updateTurnCounter(turn: 1)
        
        hideBobsBuddy = false
        adventureOpponentId = nil
        
        OpponentDeadForTracker.resetOpponentDeadForTracker()
    }
    
    func cacheBrawlInfo() {
        if let info = MirrorHelper.getBrawlInfo() {
            _brawlInfo = BrawlInfo(info: info)
        }
    }
    
    func cacheBattlegroundRatingInfo() {
        if let rating = MirrorHelper.getBattlegroundsRating() {
            _battlegroundsRating = rating
        }
    }

    private func tryToDetectWhizbangDeck() {
        if hasValidDeck {
            return
        }
        
        guard let playerEntity = player.entity else {
            return
        }
        
        if playerEntity[.whizbang_deck_id] == 0 {
            // player is not using a whizbang deck
            return
        }
        
        guard let candidates = MirrorHelper.getTemplateDecks() else {
            return
        }
        
        let mandatoryEntities = entities.map({ $0.1 }).filter({ e in
            return !e.info.created
                && (e.isMinion || e.isSpell || e.isWeapon)
                && (e.info.originalController == player.id)
        })
        
        if mandatoryEntities.count < 3 {
            // mulligan has not happened yet, come back later
            return
        }

        guard let templateDeck = candidates.first(where: { mirrorDeck in
            var mandatoryCards: [String: Int] = [:]

            mandatoryEntities.forEach {
                let oldValue = mandatoryCards[$0.cardId] ?? 0
                mandatoryCards[$0.cardId] = oldValue + 1
            }
            
            for (cardId, count) in mandatoryCards {
                if (mirrorDeck.cards.first(where: { $0.cardId == cardId })?.count.intValue ?? 0 < count) {
                    return false
                }
            }
            
            return true
        }) else {
            // looks like it's not a Whizbang deck... it shouldn't harm to come back later
            // but I don't expect it to work way better...
            return
        }
        
        let deck = Deck()
        templateDeck.cards.forEach {
            let realmCard = RealmCard()
            realmCard.id = $0.cardId
            realmCard.count = $0.count.intValue
            deck.cards.append(realmCard)
        }
        
        set(activeDeck: deck)
        playerDeckAutodetected = true
        hasValidDeck = true
        logger.info("has Valid Whizbang Deck")
    }
	func set(activeDeckId: String?, autoDetected: Bool) {
		Settings.activeDeck = activeDeckId
		playerDeckAutodetected = autoDetected
		
		if let id = activeDeckId, let deck = RealmHelper.getDeck(with: id) {
			set(activeDeck: deck)
            hasValidDeck = true
            logger.info("has Valid Mirror Deck: \(deck.cards.count) cards")
		} else {
			currentDeck = nil
			player.playerClass = nil
			updateTrackers(reset: true)
            logger.info("no Valid Mirror Deck")
		}
	}
	
    func set(activeDeck deck: Deck) {
		
        var cards: [Card] = []
        for deckCard in deck.cards {
            if let card = Cards.by(cardId: deckCard.id) {
                card.count = deckCard.count
                cards.append(card)
            }
        }
        let deckId = deck.deckId
        let name = deck.name
        let hsDeckId = deck.hsDeckId.value
        let playerClass = deck.playerClass
        let heroId = deck.heroId
        let isArena = deck.isArena
        DispatchQueue.main.async {
            cards = cards.sortCardList()
            self.currentDeck = PlayingDeck(id: deckId,
                                      name: name,
                                      hsDeckId: hsDeckId,
                                      playerClass: playerClass,
                                      heroId: heroId,
                                      cards: cards.sortCardList(),
                                      isArena: isArena
            )
            self.player.playerClass = self.currentDeck?.playerClass
            self.updateTrackers(reset: true)
        }
    }

    func removeActiveDeck() {
        currentDeck = nil
        Settings.activeDeck = nil
        updateTrackers(reset: true)
    }

    // MARK: - game state
    private func cacheMatchInfo() {
        DispatchQueue.global().async {
            var minfo: MatchInfo? = self.matchInfo
            while minfo == nil {
                logger.info("Waiting for matchInfo... (matchInfo=\(String(describing: minfo))")
                Thread.sleep(forTimeInterval: 1)
                minfo = self.matchInfo
            }
        }
    }
    
    private var lastGameStart = Date.distantPast
    func gameStart(at timestamp: LogDate) {
        logger.info("currentGameMode: \(currentGameMode), isInMenu: \(isInMenu), "
            + "handledGameEnd: \(handledGameEnd), "
            + "lastGameStartTimestamp: \(lastGameStartTimestamp), " +
            "timestamp: \(timestamp)")
        if currentGameMode == .practice && !isInMenu && !handledGameEnd
			&& lastGameStartTimestamp > LogDate(date: Date.distantPast)
            && timestamp > lastGameStartTimestamp {
            adventureRestart()
        }

        lastGameStartTimestamp = timestamp
        if lastGameStart > Date.distantPast
            && (abs(lastGameStart.timeIntervalSinceNow) < 5) {
            // game already started
            return
        }

        ImageUtils.clearCache()
        reset()
        lastGameStart = Date()
        
		gameEnded = false
        isInMenu = false
        handledGameEnd = false

        cacheMatchInfo()
        
        logger.info("----- Game Started -----")
        AppHealth.instance.setHearthstoneGameRunning(flag: true)

        NotificationManager.showNotification(type: .gameStart)

        if Settings.showTimer {
            self.turnTimer.start()
        }
		
		// update spectator information
        if spectator {
            set(activeDeckId: nil, autoDetected: false)
        }
		
        updateTrackers(reset: true)

        self.startTime = Date()
    }

    private func adventureRestart() {
        // The game end is not logged in PowerTaskList
        logger.info("Adventure was restarted. Simulating game end.")
        concede()
        loss()
        gameEnd()
        inMenu()
    }

    func gameEnd() {
        logger.info("----- Game End -----")
        AppHealth.instance.setHearthstoneGameRunning(flag: false)
		
        handleEndGame()

        secretsManager?.reset()
        updateTrackers(reset: true)
        windowManager.hideGameTrackers()
        turnTimer.stop()
    }

    func inMenu() {
        if isInMenu {
            return
        }
        logger.verbose("Game is now in menu")

        turnTimer.stop()

        isInMenu = true
    }
	
	private func generateEndgameStatistics() -> InternalGameStats? {
		let result = InternalGameStats()
		
		result.startTime = self.startTime ?? Date()
		result.endTime = Date()
		
		result.playerHero = currentDeck?.playerClass ?? player.playerClass ?? .neutral
		result.opponentHero = opponent.playerClass ?? .neutral
		
		result.wasConceded = self.wasConceded
		result.result = self.gameResult
		
        result.hearthstoneBuild = self.buildNumber
		result.season = Database.currentSeason
		
		if let name = self.player.name {
			result.playerName = name
		}
		if let _player = self.entities.map({ $0.1 }).first(where: { $0.isPlayer(eventHandler: self) }) {
			result.coin = !_player.has(tag: .first_player)
		}
		
		if let name = self.opponent.name {
			result.opponentName = name
		} else if result.opponentHero != .neutral {
			result.opponentName = result.opponentHero.rawValue
		}
		
		result.turns = self.turnNumber()
		
		result.gameMode = self.currentGameMode
		result.format = self.currentFormat
		
		if let matchInfo = self.matchInfo, self.currentGameMode == .ranked {
			let wild = self.currentFormat == .wild
            let classic = self.currentFormat == .classic
			
            if wild {
                result.playerMedalInfo = matchInfo.localPlayer.wildMedalInfo
                result.opponentMedalInfo = matchInfo.opposingPlayer.wildMedalInfo
            } else if classic {
                result.playerMedalInfo = matchInfo.localPlayer.classicMedalInfo
                result.opponentMedalInfo = matchInfo.opposingPlayer.classicMedalInfo
            } else {
                result.playerMedalInfo = matchInfo.localPlayer.standardMedalInfo
                result.opponentMedalInfo = matchInfo.opposingPlayer.standardMedalInfo
            }
		} else if self.currentGameMode == .arena {
			result.arenaLosses = self.arenaInfo?.losses ?? 0
			result.arenaWins = self.arenaInfo?.wins ?? 0
		} else if let brawlInfo = self.brawlInfo, self.currentGameMode == .brawl {
			result.brawlWins = brawlInfo.wins
			result.brawlLosses = brawlInfo.losses
		}
		
		result.gameType = self.currentGameType
		if let serverInfo = self.serverInfo {
			result.serverInfo = ServerInfo(info: serverInfo)
		}
		result.playerCardbackId = self.matchInfo?.localPlayer.cardBackId ?? 0
		result.opponentCardbackId = self.matchInfo?.opposingPlayer.cardBackId ?? 0
		result.friendlyPlayerId = self.matchInfo?.localPlayer.playerId ?? 0
        result.opposingPlayerId = self.matchInfo?.opposingPlayer.playerId ?? 0
		result.scenarioId = self.matchInfo?.missionId ?? 0
		result.brawlSeasonId = self.matchInfo?.brawlSeasonId ?? 0
		result.rankedSeasonId = self.matchInfo?.rankedSeasonId ?? 0
		result.hsDeckId = self.currentDeck?.hsDeckId
		
		self.player.revealedCards.filter({
			$0.collectible
		}).forEach({
			result.revealedCards.append($0)
		})
		
		self.opponent.opponentCardList.filter({
			!$0.isCreated
		}).forEach({
			result.opponentCards.append($0)
		})
        result.battlegroundsRating = self.battlegroundsRating ?? 0
        if currentGameType == .gt_battlegrounds || currentGameType == .gt_battlegrounds_friendly {
            result.battlegroundsRaces = self.availableRaces?.compactMap({ x in Race.allCases.firstIndex(of: x)}) ?? []
        }
		
		return result
	}

    func handleEndGame() {
		
		if self.handledGameEnd {
			logger.warning("HandleGameEnd was already called.")
			return
		}

		guard let currentGameStats = generateEndgameStatistics() else {
			logger.error("Error: could not generate endgame statistics")
			return
		}
		
		logger.verbose("currentGameStats: \(currentGameStats), "
			+ "handledGameEnd: \(self.handledGameEnd)")
		
        self.handledGameEnd = true
                
        /*if Settings.promptNotes {
            let message = NSLocalizedString("Do you want to add some notes for this game ?",
                                            comment: "")
            let frame = NSRect(x: 0, y: 0, width: 300, height: 80)
            let input = NSTextView(frame: frame)
            
            if NSAlert.show(style: .informational, message: message,
                            accessoryView: input, forceFront: true) {
                currentGameStats.note = input.string ?? ""
            }
        }*/

        if isBattlegroundsMatch() {
            OpponentDeadForTracker.resetOpponentDeadForTracker()
        }
        logger.verbose("End game: \(currentGameStats)")
        let stats = currentGameStats.toGameStats()
        // reset the turn counter
        updateTurnCounter(turn: 1)
        
        if let currentDeck = self.currentDeck {
            var skip = false
            if previousMode == Mode.adventure {
                let heroId = adventureOpponentId
                // don't add the result to statistics for Bob encounters
                if heroId == CardIds.NonCollectible.Neutral.BartenderBob || heroId == CardIds.NonCollectible.Neutral.BazaarBob {
                    skip = true
                }
            }
            if !skip, let deck = RealmHelper.getDeck(with: currentDeck.id) {
                
                RealmHelper.addStatistics(to: deck, stats: stats)
                if Settings.autoArchiveArenaDeck &&
                    self.currentGameMode == .arena && deck.isArena && deck.arenaFinished() {
                    RealmHelper.set(deck: deck, active: false)
                }
            }
        }
		
        if currentGameMode == .spectator && (currentGameStats.result == .none || currentGameStats.result == .unknown) {
            logger.info("Game was spectator mode without a game result."
                + " Probably exited spectator mode early.")
            return
        }

		self.syncStats(logLines: self.powerLog, stats: currentGameStats)
    }

	private func syncStats(logLines: [LogLine], stats: InternalGameStats) {

        guard currentGameMode != .practice && currentGameMode != .none && currentGameMode != .spectator else {
            logger.info("Game was in \(currentGameMode), don't send to third-party")
            return
        }

        if Settings.hsReplaySynchronizeMatches && (
            (stats.gameMode == .ranked &&
                Settings.hsReplayUploadRankedMatches) ||
            (stats.gameMode == .casual &&
                Settings.hsReplayUploadCasualMatches) ||
            (stats.gameMode == .arena &&
                Settings.hsReplayUploadArenaMatches) ||
            (stats.gameMode == .brawl &&
                Settings.hsReplayUploadBrawlMatches) ||
            (stats.gameMode == .practice &&
                Settings.hsReplayUploadAdventureMatches) ||
            (stats.gameMode == .friendly &&
                Settings.hsReplayUploadFriendlyMatches) ||
            (stats.gameMode == .spectator &&
                Settings.hsReplayUploadFriendlyMatches) ||
            (isBattlegroundsMatch() &&
                Settings.hsReplayUploadBattlegroundsMatches) ||
            (stats.gameMode == .duels &&
                Settings.hsReplayUploadDuelsMatches)) {
			
            let (uploadMetaData, statId) = UploadMetaData.generate(stats: stats, buildNumber: self.buildNumber,
				deck: self.playerDeckAutodetected && self.currentDeck != nil ? self.currentDeck : nil )
			
            HSReplayAPI.getUploadToken { _ in
                
                LogUploader.upload(logLines: logLines, buildNumber: self.buildNumber,
                                   metaData: (uploadMetaData, statId)) { result in
                    if case UploadResult.successful(let replayId) = result {
                        NotificationManager.showNotification(type: .hsReplayPush(replayId: replayId))
                        NotificationCenter.default
                            .post(name: Notification.Name(rawValue: Events.reload_decks), object: nil)
                    } else if case UploadResult.failed(let error) = result {
                        NotificationManager.showNotification(type: .hsReplayUploadFailed(error: error))
                    }
                }
            }
            
        }
    }

    func turnNumber() -> Int {
        if !isMulliganDone() {
            return 0
        }
        if let gameEntity = self.gameEntity {
            return (gameEntity[.turn] + 1) / 2
        }
        return 0
    }
    
    // return raw turn number, needed for BG
    func turn() -> Int {
        if let gameEntity = self.gameEntity {
            return gameEntity[.turn]
        }
        return 0
    }

    func turnsInPlayChange(entity: Entity, turn: Int) {
        guard let opponentEntity = opponentEntity else { return }

        if entity.isHero {
            let player: PlayerType = opponentEntity.isCurrentPlayer ? .opponent : .player
            if lastTurnStart[player.rawValue] >= turn {
                return
            }
            lastTurnStart[player.rawValue] = turn
            turnStart(player: player, turn: turn)
            return
        }
        secretsManager?.handleTurnsInPlayChange(entity: entity, turn: turn)
    }

    func turnStart(player: PlayerType, turn: Int) {
        if !isMulliganDone() {
            logger.info("--- Mulligan ---")
        }
        var turnNumber = turn
        if turnNumber == 0 {
            turnNumber += 1
        }
        turnQueue.insert(PlayerTurn(player: player, turn: turn))

        DispatchQueue.global().async {
            while !self.isMulliganDone() {
                Thread.sleep(forTimeInterval: 0.1)
            }
            while let playerTurn = self.turnQueue.popFirst() {
                self.handleTurnStart(playerTurn: playerTurn)
            }
        }
    }

    func handleTurnStart(playerTurn: PlayerTurn) {
        let player = playerTurn.player
        if Settings.fullGameLog {
            logger.info("Turn \(playerTurn.turn) start for player \(player) ")
        }

        if player == .player {
            self.player.onTurnStart()
            handleThaurissanCostReduction()
            secretsManager?.handlePlayerTurnStart()
        } else {
            opponent.onTurnStart()
            secretsManager?.handleOpponentTurnStart()
        }

        if turnQueue.count > 0 {
            return
        }

        var timeout = -1
        if player == .player && ((playerEntity?.has(tag: .timeout)) != nil) {
            timeout = playerEntity![.timeout]
        } else if player == .opponent && ((opponentEntity?.has(tag: .timeout)) != nil) {
            timeout = opponentEntity![.timeout]
        }
		
        turnTimer.startTurn(for: player, timeout: timeout)

        if player == .player && !isInMenu {
            if isBattlegroundsMatch() {
                OpponentDeadForTracker.shoppingStarted(game: self)
                if isMonoAvailable() != 0 && playerTurn.turn > 1 {
                    BobsBuddyInvoker.instance(turn: turnNumber()).startShopping()
                }
            }

            NotificationManager.showNotification(type: .turnStart)
        }
        
        updateTurnCounter(turn: turnNumber())
        
        updateTrackers()
    }

    func concede() {
        logger.info("Game has been conceded : (")
        self.wasConceded = true
    }

    func win() {
        logger.info("You win ¯\\_(ツ) _ / ¯")
        self.gameResult = .win

        if self.wasConceded {
            NotificationManager.showNotification(type: .opponentConcede)
        }
    }

    func loss() {
        logger.info("You lose : (")
        self.gameResult = .loss
    }

    func tied() {
        logger.info("You lose : ( / game tied: (")
        self.gameResult = .draw
    }

    func isBattlegroundsMatch() -> Bool {
        // TODO: remove
        return currentGameType == .gt_battlegrounds || currentGameType == .gt_battlegrounds_friendly
        //return true
    }
    
    func isConstructedMatch() -> Bool {
        return currentGameType == .gt_ranked || currentGameType == .gt_casual || currentGameType == .gt_vs_friend
    }
    
    func isMulliganDone() -> Bool {
        if isBattlegroundsMatch() {
                return true
        }
		let player = entities.map { $0.1 }.first { $0.isPlayer(eventHandler: self) }
        let opponent = entities.map { $0.1 }
            .first { $0.has(tag: .player_id) && !$0.isPlayer(eventHandler: self) }

        if let player = player, let opponent = opponent {
            return player[.mulligan_state] == Mulligan.done.rawValue
                && opponent[.mulligan_state] == Mulligan.done.rawValue
        }
        return false
    }

    func handleThaurissanCostReduction() {
        let thaurissans = opponent.board.filter({
            $0.cardId == CardIds.Collectible.Neutral.EmperorThaurissan && !$0.has(tag: .silenced)
        })
        if thaurissans.isEmpty {
            return
        }

        handleOpponentHandCostReduction(value: thaurissans.count)
    }
    
    func handlePlayerHandCostReduction(value: Int) {
        for card in player.hand {
            card.info.costReduction += value
        }
    }
    
    func handleOpponentHandCostReduction(value: Int) {
        for card in opponent.hand {
            card.info.costReduction += value
        }
    }
    
    func handleChameleosReveal(cardId: String) {
        self.opponent.predictUniqueCardInDeck(cardId: cardId, isCreated: false)
        self.updateOpponentTracker()
    }
    
    func handleEntityLostArmor(entity: Entity, value: Int) {
        if playerEntity?.isCurrentPlayer ?? false {
            secretsManager?.handleEntityLostArmor(entity: entity, value: value)
        }
    }
    
    func handleCardCopy() {
        self.updateOpponentTracker()
    }
    
    func set(buildNumber: Int) {
        self.buildNumber = buildNumber
    }
    
    func add(playerName: String, for ID: Int) {
        self.playerIDNameMapping[ID] = playerName
    }
    
    func playerName(for ID: Int) -> String? {
        return self.playerIDNameMapping[ID]
    }

    // MARK: - player
    func set(playerHero cardId: String) {
        if let card = Cards.hero(byId: cardId) {
            player.playerClass = card.playerClass
            player.playerClassId = cardId
            if Settings.fullGameLog {
                logger.info("Player class is \(card) ")
            }
        }
    }

    func set(playerName name: String) {
        player.name = name
    }

    func playerGet(entity: Entity, cardId: String?, turn: Int) {
        if cardId.isBlank {
            return
        }
        player.createInHand(entity: entity, turn: turn)
        updateTrackers()
    }

    func playerBackToHand(entity: Entity, cardId: String?, turn: Int) {
        if cardId.isBlank {
            return
        }
        updateTrackers()
        player.boardToHand(entity: entity, turn: turn)
    }

    func playerPlayToDeck(entity: Entity, cardId: String?, turn: Int) {
        if cardId.isBlank {
            return
        }
        player.boardToDeck(entity: entity, turn: turn)
        updateTrackers()
    }

    func playerPlay(entity: Entity, cardId: String?, turn: Int) {
        if cardId.isBlank {
            return
        }
        
        player.play(entity: entity, turn: turn)
        if let cardId = cardId, !cardId.isEmpty {
            playedCards.append(PlayedCard(player: .player, cardId: cardId, turn: turn))
        }

        if entity.has(tag: .ritual) {
            // if this entity has the RITUAL tag, it will trigger some C'Thun change
            // we wait 300ms so the proxy have the time to be updated
            let when = DispatchTime.now() + DispatchTimeInterval.milliseconds(300)
            DispatchQueue.main.asyncAfter(deadline: when) { [weak self] in
                self?.updateTrackers()
            }
        }

        secretsManager?.handleCardPlayed(entity: entity)
        updateTrackers()
    }

    func playerHandDiscard(entity: Entity, cardId: String?, turn: Int) {
        if cardId.isBlank {
            return
        }
        player.handDiscard(entity: entity, turn: turn)
        updateTrackers()
    }

    func playerSecretPlayed(entity: Entity, cardId: String?, turn: Int, fromZone: Zone) {
        if cardId.isBlank { return }

        if !entity.isSecret {
            if entity.isQuest {
                player.questPlayedFromHand(entity: entity, turn: turn)
            }
            return
        }

        switch fromZone {
        case .deck:
            player.secretPlayedFromDeck(entity: entity, turn: turn)
        case .hand:
            player.secretPlayedFromHand(entity: entity, turn: turn)
            secretsManager?.handleCardPlayed(entity: entity)
        default:
            player.createInSecret(entity: entity, turn: turn)
            return
        }
        updateTrackers()
    }
    
    func handleBeginMulligan() {
        if isBattlegroundsMatch() {
            handleBattlegroundsStart()
        } else if isConstructedMatch() {
            handleConstructedStart()
        }
    }
    
    func handleConstructedStart() {
        if Settings.showMulliganToast {
            for _ in 0 ..< 10 {
                Thread.sleep(forTimeInterval: 0.5)
                let step = gameEntity?[.step] ?? 0
                if step == 0 {
                    continue
                }
                if step > Step.begin_mulligan.rawValue {
                    break
                }

                // Wait for the game to fade in
                Thread.sleep(forTimeInterval: 3)

                if let currentDeck = currentDeck {
                    let cards = player.playerEntities.filter { x in x.isInHand && !x.info.created }.compactMap({ x in x.card.dbfId})
                    let opponentClass = opponent.playerEntities.first( where: { x in x.isHero && x.isInPlay })?.card.playerClass ?? CardClass.invalid
                    let sid = ShortIdHelper.getShortId(deck: currentDeck)
                    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1), execute: {
                        let view = MulliganToastView(frame: NSRect.zero, sid: sid, ids: cards, opponent: opponentClass)
                        view.clicked = {
                            AppDelegate.instance().coreManager.toaster.hide()
                        }
                        AppDelegate.instance().coreManager.toaster.displayToast(view: view, timeoutMillis: 10000)
                    })

                }

                break
            }
        }
    }
    
    func handlePlayerLibramReduction(change: Int) {
        player.updateLibramReduction(change: change)
    }
    
    func handleOpponentLibramReduction(change: Int) {
        opponent.updateLibramReduction(change: change)
    }
    
    func handlePlayerMulliganDone() {
        if isBattlegroundsMatch() {
            AppDelegate.instance().coreManager.toaster.hide()
        } else if isConstructedMatch() {
            AppDelegate.instance().coreManager.toaster.hide()
        }
    }
    
    func handlePlayerTechLevel(entity: Entity, techLevel: Int) {
        guard techLevel >= 1 && techLevel <= 6 else { return }
        let heroId = getCorrectBoardstateHeroId(heroId: entity.cardId)
        
        var snapshot = lastKnownBattlegroundsBoardState[heroId]
        
        if snapshot == nil {
            snapshot = BoardSnapshot(entities: [], turn: -1)
            lastKnownBattlegroundsBoardState[heroId] = snapshot
        }
        
        if let snapshot = snapshot {
            snapshot.techLevel[techLevel - 1] = turnNumber()
        }
    }
    
    func handlePlayerTriples(entity: Entity, triples: Int) {
        guard triples > 0 else { return }
        let techLevel = entity[.player_tech_level]
        guard techLevel >= 1 && techLevel <= 6 else { return }
        
        let heroId = getCorrectBoardstateHeroId(heroId: entity.cardId)

        var snapshot = lastKnownBattlegroundsBoardState[heroId]
        
        if snapshot == nil {
            snapshot = BoardSnapshot(entities: [], turn: -1)
            lastKnownBattlegroundsBoardState[heroId] = snapshot
        }
        
        if let snapshot = snapshot {
            snapshot.triples[techLevel - 1] += triples
        }
    }
    
    private func internalHandleBGStart(count: Int) {
        let heroes = player.playerEntities.filter({ x in x.isHero && x.has(tag: .bacon_hero_can_be_drafted)})
        if heroes.count < 2 {
            logger.debug("Not enough heroes")
            if count < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500), execute: {
                    self.internalHandleBGStart(count: count + 1)
                })
            } else {
                return
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500), execute: {
            let heroesArray = heroes.compactMap({ x in x.card.dbfId }).map({ x in String(x) })
            logger.debug("Battlegrounds heroes: \(heroesArray)")

            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(3), execute: {
                let view = BgHeroesToastView(frame: NSRect.zero)
                view.clicked = {
                    AppDelegate.instance().coreManager.toaster.hide()
                }
                view.heroes = heroesArray
                AppDelegate.instance().coreManager.toaster.displayToast(view: view, timeoutMillis: 10000)
            })
        })
    }
    
    private func handleBattlegroundsStart() {
        if Settings.showHeroToast {
            logger.debug("Start of battlegrounds match")
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500), execute: {
                self.internalHandleBGStart(count: 0)
            })
        }
    }

    func playerMulligan(entity: Entity, cardId: String?) {
        if cardId.isBlank {
            return
        }

        player.mulligan(entity: entity)
        updateTrackers()
    }

    func playerDraw(entity: Entity, cardId: String?, turn: Int) {
        if cardId.isBlank {
            return
        }
        if cardId == CardIds.NonCollectible.Neutral.TheCoinBasic {
            playerGet(entity: entity, cardId: cardId, turn: turn)
        } else {
            player.draw(entity: entity, turn: turn)
            updateTrackers()
        }
        secretsManager?.handleCardDrawn(entity: entity)
    }

    func playerRemoveFromDeck(entity: Entity, turn: Int) {
        player.removeFromDeck(entity: entity, turn: turn)
        updateTrackers()
    }

    func playerDeckDiscard(entity: Entity, cardId: String?, turn: Int) {
        player.deckDiscard(entity: entity, turn: turn)
        updateTrackers()
    }

    func playerDeckToPlay(entity: Entity, cardId: String?, turn: Int) {
        player.deckToPlay(entity: entity, turn: turn)
        updateTrackers()
    }

    func playerPlayToGraveyard(entity: Entity, cardId: String?, turn: Int, playersTurn: Bool) {
        player.playToGraveyard(entity: entity, cardId: cardId, turn: turn)
        if playersTurn && entity.isMinion {
            playerMinionDeath(entity: entity)
        }
        
        // a workaround to fix (#1080) by double-checking the secrets after a spell takes effect,
        // e.g., summoned a minion.
        if playersTurn && entity.isSpell {
            secretsManager?.handleCardPlayed(entity: entity)
        }
        
        updateTrackers()
    }

    func playerJoust(entity: Entity, cardId: String?, turn: Int) {
        player.joustReveal(entity: entity, turn: turn)
        updateTrackers()
    }

    func playerGetToDeck(entity: Entity, cardId: String?, turn: Int) {
        player.createInDeck(entity: entity, turn: turn)
        updateTrackers()
    }

    func playerFatigue(value: Int) {
        if Settings.fullGameLog {
            logger.info("Player get \(value) fatigue")
        }
        player.fatigue = value
        updateTrackers()
    }

    func playerCreateInPlay(entity: Entity, cardId: String?, turn: Int) {
        player.createInPlay(entity: entity, turn: turn)
    }

    func playerStolen(entity: Entity, cardId: String?, turn: Int) {
        player.stolenByOpponent(entity: entity, turn: turn)
        opponent.stolenFromOpponent(entity: entity, turn: turn)

        if entity.isSecret {
            var heroClass: CardClass?
            var className = "\(entity[.class])"
            if !className.isBlank {
                className = className.lowercased()
                heroClass = CardClass(rawValue: className)
                if heroClass == .none {
                    if let playerClass = opponent.playerClass {
                        heroClass = playerClass
                    }
                }
            } else {
                if let playerClass = opponent.playerClass {
                    heroClass = playerClass
                }
            }
            guard heroClass != nil else { return }
            secretsManager?.newSecret(entity: entity)
        }
    }

    func playerRemoveFromPlay(entity: Entity, turn: Int) {
        player.removeFromPlay(entity: entity, turn: turn)
    }

    func playerCreateInSetAside(entity: Entity, turn: Int) {
        player.createInSetAside(entity: entity, turn: turn)
    }

    func playerHeroPower(cardId: String, turn: Int) {
        player.heroPower(turn: turn)
        if Settings.fullGameLog {
            logger.info("Player Hero Power \(cardId) \(turn) ")
        }

        secretsManager?.handleHeroPower()
    }

    // MARK: - Opponent actions
    func set(opponentHero cardId: String) {
        if let card = Cards.hero(byId: cardId) {
            opponent.playerClass = card.playerClass
            opponent.playerClassId = cardId
            updateTrackers()
            if Settings.fullGameLog {
                logger.info("Opponent class is \(card) ")
            }
        }
    }

    func set(opponentName name: String) {
        opponent.name = name
        updateTrackers()
    }

    func opponentGet(entity: Entity, turn: Int, id: Int) {
        if !isMulliganDone() && entity[.zone_position] == 5 {
            entity.cardId = CardIds.NonCollectible.Neutral.TheCoinBasic
        }

        opponent.createInHand(entity: entity, turn: turn)
        updateTrackers()
    }

    func opponentPlayToHand(entity: Entity, cardId: String?, turn: Int, id: Int) {
        opponent.boardToHand(entity: entity, turn: turn)
        updateTrackers()
    }

    func opponentPlayToDeck(entity: Entity, cardId: String?, turn: Int) {
        opponent.boardToDeck(entity: entity, turn: turn)
        updateTrackers()
    }

    func opponentPlay(entity: Entity, cardId: String?, from: Int, turn: Int) {
        opponent.play(entity: entity, turn: turn)

        if let cardId = cardId, !cardId.isEmpty {
            playedCards.append(PlayedCard(player: .opponent, cardId: cardId, turn: turn))
        }

        if entity.has(tag: .ritual) {
            // if this entity has the RITUAL tag, it will trigger some C'Thun change
            // we wait 300ms so the proxy have the time to be updated
            let when = DispatchTime.now() + DispatchTimeInterval.milliseconds(300)
            DispatchQueue.main.asyncAfter(deadline: when) { [weak self] in
                self?.updateTrackers()
            }
        }
        updateTrackers()
    }

    func opponentHandDiscard(entity: Entity, cardId: String?, from: Int, turn: Int) {
        opponent.handDiscard(entity: entity, turn: turn)
        updateTrackers()
    }

    func opponentSecretPlayed(entity: Entity, cardId: String?,
                              from: Int, turn: Int,
                              fromZone: Zone, otherId: Int) {
        if !entity.isSecret {
            if entity.isQuest {
                opponent.questPlayedFromHand(entity: entity, turn: turn)
            }
            return
        }

        switch fromZone {
        case .deck:
            opponent.secretPlayedFromDeck(entity: entity, turn: turn)
        case .hand:
            opponent.secretPlayedFromHand(entity: entity, turn: turn)
        default:
            opponent.createInSecret(entity: entity, turn: turn)
        }

        var heroClass: CardClass?
        let className = "\(entity[.class])".lowercased()
        if let tagClass = TagClass(rawValue: entity[.class]) {
            heroClass = tagClass.cardClassValue
        } else if let _heroClass = CardClass(rawValue: className), !className.isBlank {
            heroClass = _heroClass
        } else if let playerClass = opponent.playerClass {
            heroClass = playerClass
        }

        if Settings.fullGameLog {
            logger.info("Secret played by \(entity[.class])"
                + " -> \(String(describing: heroClass)) "
                + "-> \(String(describing: opponent.playerClass))")
        }
        if heroClass != nil {
            secretsManager?.newSecret(entity: entity)
        }
        updateTrackers()
    }

    func opponentMulligan(entity: Entity, from: Int) {
        opponent.mulligan(entity: entity)
        updateTrackers()
    }

    func opponentDraw(entity: Entity, turn: Int) {
        opponent.draw(entity: entity, turn: turn)
        updateTrackers()
    }

    func opponentRemoveFromDeck(entity: Entity, turn: Int) {
        opponent.removeFromDeck(entity: entity, turn: turn)
        updateTrackers()
    }

    func opponentDeckDiscard(entity: Entity, cardId: String?, turn: Int) {
        opponent.deckDiscard(entity: entity, turn: turn)
        updateTrackers()
    }

    func opponentDeckToPlay(entity: Entity, cardId: String?, turn: Int) {
        opponent.deckToPlay(entity: entity, turn: turn)
        updateTrackers()
    }

    func opponentPlayToGraveyard(entity: Entity, cardId: String?,
                                 turn: Int, playersTurn: Bool) {
        opponent.playToGraveyard(entity: entity, cardId: cardId, turn: turn)
        if playersTurn && entity.isMinion {
            opponentMinionDeath(entity: entity, turn: turn)
        }
        if !playersTurn && entity.info.wasTransformed {
            Thread.sleep(forTimeInterval: 3.0)
            if let transformedSecret = secretsManager?.secrets.filter({ x in x.entity.id == entity.id }).first {
                secretsManager?.removeSecret(entity: transformedSecret.entity)
            }
            
        }
        updateTrackers()
    }

    func opponentJoust(entity: Entity, cardId: String?, turn: Int) {
        opponent.joustReveal(entity: entity, turn: turn)
        updateTrackers()
    }

    func opponentGetToDeck(entity: Entity, turn: Int) {
        opponent.createInDeck(entity: entity, turn: turn)
        updateTrackers()
    }

    func opponentSecretTrigger(entity: Entity, cardId: String?, turn: Int, otherId: Int) {
        if !entity.isSecret { return }

        opponent.secretTriggered(entity: entity, turn: turn)
        secretsManager?.removeSecret(entity: entity)
    }

    func opponentFatigue(value: Int) {
        opponent.fatigue = value
        updateTrackers()
    }

    func opponentCreateInPlay(entity: Entity, cardId: String?, turn: Int) {
        opponent.createInPlay(entity: entity, turn: turn)
    }

    func opponentStolen(entity: Entity, cardId: String?, turn: Int) {
        opponent.stolenByOpponent(entity: entity, turn: turn)
        player.stolenFromOpponent(entity: entity, turn: turn)

        if entity.isSecret {
            secretsManager?.removeSecret(entity: entity)
        }
    }

    func opponentRemoveFromPlay(entity: Entity, turn: Int) {
        player.removeFromPlay(entity: entity, turn: turn)
    }

    func opponentCreateInSetAside(entity: Entity, turn: Int) {
        opponent.createInSetAside(entity: entity, turn: turn)
    }

    func opponentHeroPower(cardId: String, turn: Int) {
        opponent.heroPower(turn: turn)
        if Settings.fullGameLog {
            logger.info("Opponent Hero Power \(cardId) \(turn) ")
        }
        updateTrackers()
    }

    // MARK: - Game actions
    func defending(entity: Entity?) {
        self.defendingEntity = entity
        if let attackingEntity = self.attackingEntity,
            let defendingEntity = self.defendingEntity,
            let entity = entity {
            if entity.isControlled(by: opponent.id) {
                secretsManager?.handleAttack(attacker: attackingEntity, defender: defendingEntity)
            }
        }
    }

    func attacking(entity: Entity?) {
        self.attackingEntity = entity
        if let attackingEntity = self.attackingEntity,
            let defendingEntity = self.defendingEntity,
            let entity = entity {
            if entity.isControlled(by: player.id) {
                secretsManager?.handleAttack(attacker: attackingEntity, defender: defendingEntity)
            }
        }
    }

    func playerMinionPlayed(entity: Entity) {
        secretsManager?.handleMinionPlayed(entity: entity)
    }
    
    func playerMinionDeath(entity: Entity) {
        secretsManager?.handlePlayerMinionDeath(entity: entity)
    }

    func opponentMinionDeath(entity: Entity, turn: Int) {
        secretsManager?.handleOpponentMinionDeath(entity: entity)
    }

    func opponentDamage(entity: Entity, damage: Int) {
        secretsManager?.handleOpponentDamage(entity: entity, damage: damage)
    }

    func opponentTurnStart(entity: Entity) {

    }
    
    func startCombat() {
        snapshotBattlegroundsBoardState()
        
        if isMonoAvailable() == 0 {
            return
        }
        
        BobsBuddyInvoker.instance(turn: turnNumber()).startCombat()
    }
    
    var chameleosReveal: (Int, String)?
	
	// MARK: - Arena
	
	func setArenaOptions(cards: [Card]) {
		self.windowManager.arenaHelper.set(cards: cards)
		self.updateArenaHelper()
	}
}

// MARK: NSWindowDelegate functions
extension Game: NSWindowDelegate {
    
    func windowDidResize(_ notification: Notification) {
        
        guard let window = notification.object as? NSWindow else { return }
        
        if window == self.windowManager.playerTracker.window {
            self.updatePlayerTracker(reset: false)
            onWindowMove(tracker: self.windowManager.playerTracker)
        } else if window == self.windowManager.opponentTracker.window {
            self.updateOpponentTracker(reset: false)
            onWindowMove(tracker: self.windowManager.opponentTracker)
        }
    }
    
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window == self.windowManager.playerTracker.window {
            onWindowMove(tracker: self.windowManager.playerTracker)
        } else if window == self.windowManager.opponentTracker.window {
            onWindowMove(tracker: self.windowManager.opponentTracker)
        }
    }
    
    private func onWindowMove(tracker: Tracker) {
        if !tracker.isWindowLoaded || !tracker.hasValidFrame {return}
        if tracker.playerType == .player {
            Settings.playerTrackerFrame = tracker.window?.frame
        } else {
            Settings.opponentTrackerFrame = tracker.window?.frame
        }
    }
}
