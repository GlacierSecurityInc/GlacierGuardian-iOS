//
//  VMPlayerViewController.swift
//  Glacier
//
//  Created by andyfriedman on 3/4/25.
//  Copyright © 2025 Glacier. All rights reserved.
//

import UIKit
import AVFoundation

class VMPlayerViewController: UIViewController {

    // UI Elements
    var callerNameLabel: UILabel!
    var voicemailTimeLabel: UILabel!
    var playPauseButton: UIButton!
    var deleteButton: UIButton!
    var speakerButton: UIButton!
    var phoneButton: UIButton!
    var progressBar: UIProgressView!
    
    var preDurationLabel: UILabel!
    var postDurationLabel: UILabel!
    
    var voicemailDuration: Int = 0
    var currentTime: Int = 0
    var speakerOn = false
    var currentVolume = Float(1.0)
    var firstPlay = true
    
    // Audio Player
    var audioPlayer: AVPlayer?
    var timer: Timer?
    var audioPlayerObserver: Any?
    
    // Voicemail Data
    var voicemailRec: VoicemailRecord!
    var voicemailTime: String! //exists in rec, but this is formatted
    
    var playIconChar: UniChar!
    var pauseIconChar: UniChar!
    var speakerOnIconChar: UniChar!
    //var speakerOffIconChar: UniChar!
    var vmUpdateDelegate: VMUpdateDelegate?
    
    override func viewDidLoad() {
        super.viewDidLoad()

        setupUI()
        //loadVoicemailData()
        setupAudioPlayer()
        startAudioPlayerObserver()
    }
    
    // Setup UI
    func setupUI() {
        //self.view.backgroundColor = .white
        
        // Caller Name Label
        callerNameLabel = UILabel()
        callerNameLabel.text = voicemailRec.contact?.name ?? voicemailRec.from!
        callerNameLabel.font = UIFont.systemFont(ofSize: 18)
        callerNameLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(callerNameLabel)
        
        // Voicemail Time Label
        voicemailTimeLabel = UILabel()
        voicemailTimeLabel.text = voicemailTime
        voicemailTimeLabel.font = UIFont.systemFont(ofSize: 16)
        voicemailTimeLabel.textColor = .lightGray
        voicemailTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(voicemailTimeLabel)
        
        // Progress Bar
        progressBar = UIProgressView(progressViewStyle: .default)
        progressBar.progress = 0.0
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressBar)
        
        // Voicemail Duration Label
        preDurationLabel = UILabel()
        preDurationLabel.text = formattedDuration(currentTime)
        preDurationLabel.font = UIFont.systemFont(ofSize: 12)
        preDurationLabel.textColor = .lightGray
        preDurationLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(preDurationLabel)
        
        // Voicemail Duration Label
        postDurationLabel = UILabel()
        postDurationLabel.text = "-"+formattedDuration(voicemailDuration)
        postDurationLabel.font = UIFont.systemFont(ofSize: 12)
        postDurationLabel.textColor = .lightGray
        postDurationLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(postDurationLabel)
        
        // Play/Pause Button
        playPauseButton = UIButton(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        playPauseButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 4.0, leading: 8.0, bottom: 4.0, trailing: 8.0)
        playPauseButton.titleLabel?.font = UIFont(name: kFontAwesomeFont, size: 22)
        playPauseButton.titleLabel?.textAlignment = NSTextAlignment.center
        //playPauseButton.tintColor = .blue
        playPauseButton.setTitleColor(.appleBlue(), for: UIControl.State.normal)
        if self.traitCollection.userInterfaceStyle == .dark {
            playPauseButton.setTitleColor(.white, for: UIControl.State.normal)
        }
        playIconChar = 0xf04b
        pauseIconChar = 0xf04c
        playPauseButton.setTitle(String(format: "%C", playIconChar), for: .normal)
        playPauseButton.addTarget(self, action: #selector(playPauseAction), for: .touchUpInside)
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playPauseButton)
        
        // Speaker Button
        speakerButton = UIButton(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        speakerButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 4.0, leading: 8.0, bottom: 4.0, trailing: 8.0)
        speakerButton.titleLabel?.font = UIFont(name: kFontAwesomeFont, size: 22)
        speakerButton.titleLabel?.textAlignment = NSTextAlignment.center
        speakerButton.tintColor = .lightGray
        speakerButton.setTitleColor(.white, for: UIControl.State.normal)
        //let speakerIconChar: UniChar = 0xf04b
        speakerOnIconChar = 0xf028//  f6a8
        //speakerOffIconChar = 0xf026 //f2e2
        speakerButton.setTitle(String(format: "%C", speakerOnIconChar), for: .normal)
        
        speakerButton.backgroundColor = .systemGray
        speakerButton.addTarget(self, action: #selector(speakerAction), for: .touchUpInside)
        speakerButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(speakerButton)
        
        // Call Button
        phoneButton = UIButton(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        phoneButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 4.0, leading: 8.0, bottom: 4.0, trailing: 8.0)
        phoneButton.titleLabel?.font = UIFont(name: kFontAwesomeFont, size: 22)
        phoneButton.titleLabel?.textAlignment = NSTextAlignment.center
        phoneButton.tintColor = .lightGray
        phoneButton.setTitleColor(.label, for: UIControl.State.normal)
        let phoneIconChar: UniChar = 0xf095
        phoneButton.setTitle(String(format: "%C", phoneIconChar), for: .normal)
        phoneButton.backgroundColor = .appleBlue()
        phoneButton.addTarget(self, action: #selector(callAction), for: .touchUpInside)
        phoneButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(phoneButton)
        
        // Delete Button
        deleteButton = UIButton(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        deleteButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 4.0, leading: 8.0, bottom: 4.0, trailing: 8.0)
        deleteButton.titleLabel?.font = UIFont(name: kFontAwesomeFont, size: 22)
        deleteButton.titleLabel?.textAlignment = NSTextAlignment.center
        deleteButton.tintColor = .lightGray
        deleteButton.setTitleColor(.label, for: UIControl.State.normal)
        let deleteIconChar: UniChar = 0xf1f8
        deleteButton.setTitle(String(format: "%C", deleteIconChar), for: .normal)
        deleteButton.backgroundColor = #colorLiteral(red: 1, green: 0.3138658217, blue: 0.1892755682, alpha: 1)
        deleteButton.addTarget(self, action: #selector(deleteVoicemail), for: .touchUpInside)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(deleteButton)
        
        self.setupConstraints()
        
        let radius = 40.0/2.0
        playPauseButton.layer.cornerRadius = radius
        deleteButton.layer.cornerRadius = radius
        speakerButton.layer.cornerRadius = radius
        phoneButton.layer.cornerRadius = radius
    }
    
    func setupConstraints() {
        callerNameLabel.autoPinEdge(toSuperviewSafeArea: .top, withInset: OTRBuddyImageCellPadding)
        callerNameLabel.autoPinEdge(toSuperviewEdge: .leading, withInset: OTRBuddyImageCellPadding)
            
        voicemailTimeLabel.autoPinEdge(.top, to: .bottom, of: callerNameLabel, withOffset:2.0)
        voicemailTimeLabel.autoPinEdge(toSuperviewEdge: .leading, withInset: OTRBuddyImageCellPadding)
            
        progressBar.autoPinEdge(.top, to: .bottom, of: voicemailTimeLabel, withOffset:OTRBuddyImageCellPadding)
        progressBar.autoPinEdge(toSuperviewEdge: .leading, withInset: OTRBuddyImageCellPadding)
        progressBar.autoPinEdge(toSuperviewEdge: .trailing, withInset: OTRBuddyImageCellPadding)
        
        preDurationLabel.autoPinEdge(.top, to: .bottom, of: progressBar, withOffset:2.0)
        preDurationLabel.autoPinEdge(toSuperviewEdge: .leading, withInset: OTRBuddyImageCellPadding)
        
        postDurationLabel.autoPinEdge(.top, to: .bottom, of: progressBar, withOffset:2.0)
        postDurationLabel.autoPinEdge(toSuperviewEdge: .trailing, withInset: OTRBuddyImageCellPadding)
            
        playPauseButton.autoPinEdge(.top, to: .bottom, of: progressBar, withOffset:OTRBuddyImageCellPadding*3)
        playPauseButton.autoPinEdge(toSuperviewEdge: .leading, withInset: OTRBuddyImageCellPadding)
        playPauseButton.autoSetDimensions(to: CGSize(width: 40, height: 40))
        
        deleteButton.autoSetDimensions(to: CGSize(width: 40, height: 40))
        deleteButton.autoPinEdge(.top, to: .bottom, of: progressBar, withOffset:OTRBuddyImageCellPadding*3)
        deleteButton.autoPinEdge(toSuperviewEdge: .trailing, withInset: OTRBuddyImageCellPadding)
        
        phoneButton.autoSetDimensions(to: CGSize(width: 40, height: 40))
        phoneButton.autoPinEdge(.top, to: .bottom, of: progressBar, withOffset:OTRBuddyImageCellPadding*3)
        phoneButton.autoPinEdge(.trailing, to: .leading, of: deleteButton, withOffset:-OTRBuddyImageCellPadding*2)
        
        speakerButton.autoPinEdge(.top, to: .bottom, of: progressBar, withOffset:OTRBuddyImageCellPadding*3)
        speakerButton.autoPinEdge(.trailing, to: .leading, of: phoneButton, withOffset:-OTRBuddyImageCellPadding*2)
        speakerButton.autoSetDimensions(to: CGSize(width: 40, height: 40))
    }
    
    override open func viewWillDisappear(_ animated: Bool) {
        if speakerOn {
            self.speakerAction()
        }
        super.viewWillDisappear(animated)
    }
    
    // Setup Audio Player
    func setupAudioPlayer() {
        if let urlstr = self.voicemailRec.url, let url = URL(string: urlstr) {
            audioPlayer = AVPlayer(url: url)
        }
    }
    
    // Play/Pause Action
    @objc func playPauseAction() {
        guard let player = audioPlayer else { return }
        
        if player.timeControlStatus == .paused {
            if firstPlay {
                NotificationCenter.default.addObserver(self, selector: #selector(didFinishPlaying), name: AVPlayerItem.didPlayToEndTimeNotification, object: nil)
                TwilioBackendManager.sharedMgr().listenedToVM(voicemailRec.recordingSid!)
                firstPlay = false
            }
            player.play()
            playPauseButton.setTitle(String(format: "%C", pauseIconChar), for: .normal)
        } else {
            player.pause()
            playPauseButton.setTitle(String(format: "%C", playIconChar), for: .normal)
        }
    }
    
    @objc func speakerAction() {
        if speakerOn {
            speakerOn = false
            speakerButton.backgroundColor = .systemGray
            self.audioPlayer?.volume = self.currentVolume
            do {
                try AVAudioSession.sharedInstance().overrideOutputAudioPort(AVAudioSession.PortOverride.none)
            } catch {
                DDLogInfo("Fail: \(error.localizedDescription)")
            }
        } else {
            speakerOn = true
            speakerButton.backgroundColor = .appleBlue()
            if let curvol = self.audioPlayer?.volume {
                self.currentVolume = curvol
            }
            
            do {
                try AVAudioSession.sharedInstance().overrideOutputAudioPort(AVAudioSession.PortOverride.speaker)
            } catch {
                print("Couldn't override output audio port")
            }
            
            self.audioPlayer?.volume = 80
        }
    }
    
    @objc func callAction() {
        if CallManager.sharedCallManager().checkAudioPermissions() == true {
            AVAudioSession.sharedInstance().requestRecordPermission({ [weak self] (granted) in
                DispatchQueue.main.async {
                    if (granted) { return }
                    let alert = UIAlertController(title: "Allow Audio", message: "Whoops! It looks like you have not permitted Glacier to access your Microphone. To use Glacier calling, please enable the Microphone in the Glacier settings on your device.", preferredStyle: .alert)
                    let enableAction = UIAlertAction(title: "Enable", style: .default, handler: { alert in
                        if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(settingsURL)
                        }
                    })
                    let cancelAction = UIAlertAction(title: "Cancel", style: .default, handler: nil)
                    alert.addAction(enableAction)
                    alert.addAction(cancelAction)
                    self?.present(alert, animated: true, completion: nil)
                }
            })
        }
            
        //IOSM-509 prevent accidental hot mic
        let alert = UIAlertController(title: "Start Call?", message: nil, preferredStyle: .alert)
        let callAction = UIAlertAction(title: "Call", style: .default, handler: { alert in
            let number = CallManager.cleanPhoneNumber(self.voicemailRec.from!)
            let name = self.voicemailRec.contact?.name ?? self.voicemailRec.from!
            CallManager.sharedCallManager().makeVoiceCall(number, name: name)
            self.navigationController?.popViewController(animated: true)
        })
        let cancelAction = UIAlertAction(title: "Cancel", style: .default, handler: nil)
        alert.addAction(callAction)
        alert.addAction(cancelAction)
        self.present(alert, animated: true, completion: nil)
    }
    
    // Delete Voicemail Action
    @objc func deleteVoicemail() {
        TwilioBackendManager.sharedMgr().deleteVM(voicemailRec.recordingSid!)
        vmUpdateDelegate?.vmStatusUpdated(voicemailRec.recordingSid!, status: TwilioBackendManager.deleteVMStatus)
        self.navigationController?.popViewController(animated: true)
    }
    
    // MARK: - Player Progress Observer
    func startAudioPlayerObserver() {
        audioPlayerObserver = audioPlayer?.addPeriodicTimeObserver(forInterval: CMTimeMake(value: 1, timescale: 10), queue: DispatchQueue.main, using: { [weak self] (time) in
            self?.updateProgressBar(time: time)
        })
    }
    
    @objc func didFinishPlaying() {
        preDurationLabel.text = formattedDuration(voicemailDuration)
        postDurationLabel.text = "-"+formattedDuration(0)
        progressBar.setProgress(1.0, animated: true)
        playPauseButton.setTitle(String(format: "%C", playIconChar), for: .normal)
    }
    
    // Update progress bar based on the current time of the audio player
    func updateProgressBar(time: CMTime) {
        let currentTimeFl = CMTimeGetSeconds(time)
        currentTime = Int(currentTimeFl)
        preDurationLabel.text = formattedDuration(currentTime)
        postDurationLabel.text = "-"+formattedDuration(voicemailDuration - currentTime)
        let progress = Float(currentTimeFl) / Float(voicemailDuration)
        //print("***** progress \(progress) with \(currentTime)/\(voicemailDuration)")
        progressBar.setProgress(progress, animated: true)
    }
    
    // Helper Methods
    func formattedDuration(_ duration:Int) -> String {
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "%01d:%02d", minutes, seconds)
    }
    
    /*func formattedTime() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        return dateFormatter.string(from: voicemailTime)
    }*/
    
    deinit {
        if let observer = audioPlayerObserver {
            audioPlayer?.removeTimeObserver(observer)
        }
        NotificationCenter.default.removeObserver(self)
    }
}
