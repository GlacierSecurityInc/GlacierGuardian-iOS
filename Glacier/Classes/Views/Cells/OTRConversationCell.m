//
//  OTRConversationCell.m
//  Off the Record
//
//  Created by David Chiles on 3/3/14.
//  Copyright (c) 2014 Chris Ballinger. All rights reserved.
//

#import "OTRConversationCell.h"
@import BButton;
#import "Glacier-Swift.h"

@interface OTRConversationCell ()

@property (nonatomic, strong) NSArray *verticalConstraints;
@property (nonatomic, strong) NSArray *accountHorizontalConstraints;

@end

@implementation OTRConversationCell

- (id) initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if (self = [super initWithStyle:style reuseIdentifier:reuseIdentifier]) {
        self.showAccountLabel = NO;
        
        //UIFont *faFontSmall = [UIFont fontWithName:kFontAwesomeFont size:[UIFont smallSystemFontSize]-1];
        //UIFont *faFontLarger = [UIFont fontWithName:kFontAwesomeFont size:[UIFont systemFontSize]];
        
        UIColor *lblColor = lblColor = [UIColor labelColor];
        
        UIFontDescriptor *userFont = [UIFontDescriptor preferredFontDescriptorWithTextStyle:UIFontTextStyleBody];
        float smallFontSize = [userFont pointSize]-6;
        UIFont *faFontSmall = [UIFont fontWithName:kFontAwesomeFont size:smallFontSize];
        float largeFontSize = [userFont pointSize]-3;
        UIFont *faFontLarger = [UIFont fontWithName:kFontAwesomeFont size:largeFontSize];
        
        //UIColor *darkGreyColor = [UIColor colorWithWhite:.45 alpha:1.0];
        UIColor *lightGreyColor = [UIColor colorWithWhite:.6 alpha:1.0];
        self.dateLabel = [[UILabel alloc] init];
        self.dateLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.dateLabel.font = faFontSmall;
        self.dateLabel.textColor = lblColor;
        
        self.nameLabel = [[UILabel alloc] init];
        self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.nameLabel.font = faFontLarger;
        self.nameLabel.textColor = lblColor;
        
        self.conversationLabel = [[UILabel alloc] init];
        self.conversationLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.conversationLabel.lineBreakMode = NSLineBreakByWordWrapping;
        self.conversationLabel.numberOfLines = 0;
        self.conversationLabel.font = faFontSmall;
        self.conversationLabel.textColor = lightGreyColor;
        
        self.accountLabel = [[UILabel alloc] init];
        self.accountLabel.translatesAutoresizingMaskIntoConstraints = NO;
        
        [self.contentView addSubview:self.dateLabel];
        [self.contentView addSubview:self.nameLabel];
        [self.contentView addSubview:self.conversationLabel];
        
    }
    return self;
}

- (void)setShowAccountLabel:(BOOL)showAccountLabel
{
    _showAccountLabel = showAccountLabel;
    
    if (!self.showAccountLabel) {
        [self.accountLabel removeFromSuperview];
    }
    else {
        [self.contentView addSubview:self.accountLabel];
    }
}

- (void)setRoomThread:(ChatRoomModel *)room {
    [super setRoomThread:room];
    
    ChatAccountModel *account = [ChatAccountModel getXMPPAccountWithUniqueId:room.threadAccountIdentifier];
    
    id <MessageProtocol> lastMessage = [room lastMessage];
    // this is so we can show who sent a group message
    ChatBuddyModel *groupBuddy = [lastMessage xmppBuddy];
    [self setThreadWith:lastMessage name:[room threadName] displayName:groupBuddy.displayName account:account unreadMessages:[room numberOfUnreadMessages] isGroup:YES];
}

- (void)setBuddyThread:(ChatBuddyModel *)buddy {
    [super setBuddyThread:buddy];
    
    ChatAccountModel *account = [ChatAccountModel getXMPPAccountWithUniqueId:[buddy threadAccountIdentifier]];
    
    id <MessageProtocol> lastMessage = [buddy lastMessage];
    [self setThreadWith:lastMessage name:[buddy threadName] displayName:buddy.displayName account:account unreadMessages:[buddy numberOfUnreadMessages] isGroup:NO];
}

- (void)setThreadWith:(id <MessageProtocol>)lastMessage name:(NSString *)nameString displayName:(NSString *)displayName account:(ChatAccountModel *)chatAccount unreadMessages:(NSUInteger)unreadMessages isGroup:(BOOL)isGroup {
    self.nameLabel.text = nameString;
    ChatMediaItemModel *mediaItem = nil;
    if (lastMessage.messageMediaItemKey) {
        mediaItem = [ChatMediaItemModel getMediaItemWith:lastMessage.messageMediaItemKey];
    }
    
    self.accountLabel.text = chatAccount.username;
    
    NSString *shortusername = nil; // aka 'username' from username@example.com
    NSArray *acctcomponents = [chatAccount.username componentsSeparatedByString:@"@"];
    if (acctcomponents.count == 2) {
        shortusername = [acctcomponents firstObject];
        self.accountLabel.text = shortusername;
    }
    NSString *shortnamestring = nil; // aka 'username' from username@example.com
    NSArray *namecomponents = [nameString componentsSeparatedByString:@"@"];
    if (namecomponents.count == 2) {
        shortnamestring = [namecomponents firstObject];
        self.nameLabel.text = shortnamestring;
    }
    
    NSError *messageError = lastMessage.messageError;
    NSString *messageText = lastMessage.messageText;
    if (!messageText) {
        messageText = @"";
    }
    
    NSString *messageTextPrefix = @"";
    if (!lastMessage.isMessageIncoming && !lastMessage.isSystemUpdate) {
        NSString *you = GROUP_INFO_YOU().localizedCapitalizedString;
        messageTextPrefix = [NSString stringWithFormat:@"%@: ", you];
    } else if (isGroup) {
        NSString *displayName = displayName;
        if (displayName.length) {
            messageTextPrefix = [NSString stringWithFormat:@"%@: ", displayName];
        }
    }
    
    if (isGroup) {
        //self.nameLabel.text = [NSString stringWithFormat: @"#%@", self.nameLabel.text];
        
        if (mediaItem == nil && (messageText.length == 0 || [messageText hasSuffix:@" the group"])) {
            messageTextPrefix = @"";
        }
    }
    
    if ([messageText hasPrefix:@"geo:"]) {
        messageText = [NSString stringWithFormat:@"%@ Location sent", [NSString fa_stringForFontAwesomeIcon:FAIconMapMarker]];
    }
    
    if (messageError &&
        !messageError.isAutomaticDownloadError && !lastMessage.isMessageIncoming && ![messageError.domain isEqualToString:@"Alamofire.AFError"]) { // !AFError
        if (!messageText.length) {
            messageText = ERROR_STRING();
        }
        self.conversationLabel.text = @"⚠️ Unable to send message";  //changed from "image"
    } else if (mediaItem) {
        self.conversationLabel.text = [messageTextPrefix stringByAppendingString:[mediaItem getMediaDisplayText]];
    } else if ([messageText hasPrefix:@"aesgcm"]) {
        self.conversationLabel.text = [messageTextPrefix stringByAppendingString:@"Media"];
    } else {
        self.conversationLabel.text = [messageTextPrefix stringByAppendingString:messageText];
    }
    
    UIColor *lblColor = [UIColor labelColor];
    self.nameLabel.textColor = lblColor;
    if (unreadMessages > 0) {
        [self markUnread];
    } else {
        [self markRead];
    }
    
    self.dateLabel.textColor = lblColor;
    [self updateDateString:lastMessage.messageDate];
    
    if (messageError && [messageError.domain isEqualToString:@"Alamofire.AFError"]) {
        self.dateLabel.text = [NSString stringWithFormat:@"%@ %@", [NSString fa_stringForFontAwesomeIcon:FAIconClockO], self.dateLabel.text];
    } else if (lastMessage && !lastMessage.isMessageIncoming && !lastMessage.isSystemUpdate && !lastMessage.isMessageSent) {
        self.dateLabel.text = [NSString stringWithFormat:@"%@ %@", [NSString fa_stringForFontAwesomeIcon:FAIconClockO], self.dateLabel.text];
    }
}

- (void) markAllRead:(id)sender {
    [[OTRAppDelegate appDelegate] markAllRead];
}

- (void)updateDateString:(NSDate *)date
{
    self.dateLabel.text = [self dateString:date];
}

- (NSString *)dateString:(NSDate *)messageDate
{
    if (!messageDate) {
        return @"";
    }
    NSTimeInterval timeInterval = fabs([messageDate timeIntervalSinceNow]);
    NSString * dateString = nil;
    if (timeInterval < 60){
        dateString = @"Now";
    }
    else if (timeInterval < 60*60) {
        int minsInt = timeInterval/60;
        NSString * minString = @"mins";
        if (minsInt == 1) {
            minString = @"min";
        }
        dateString = [NSString stringWithFormat:@"%d %@",minsInt,minString];
    }
    else if (timeInterval < 60*60*24){
        // show time in format 11:00 PM
        dateString = [NSDateFormatter localizedStringFromDate:messageDate dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle];
    }
    else if (timeInterval < 60*60*24*7) {
        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
        dateFormatter.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"EEE" options:0 locale:[NSLocale currentLocale]];
        dateString = [dateFormatter stringFromDate:messageDate];
        
    }
    else if (timeInterval < 60*60*25*365) {
        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
        dateFormatter.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"dMMM" options:0
                                                                   locale:[NSLocale currentLocale]];
        dateString = [dateFormatter stringFromDate:messageDate];
    }
    else {
        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
        dateFormatter.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"dMMMYYYY" options:0
                                                                    locale:[NSLocale currentLocale]];
        dateString = [dateFormatter stringFromDate:messageDate];
    }
    
    
    
    return dateString;
}

- (void)updateConstraints
{
    NSDictionary *views = @{@"unreadView": self.unreadImageView,
                            @"imageView": self.avatarImageView,
                            @"conversationLabel": self.conversationLabel,
                            @"dateLabel":self.dateLabel,
                            @"nameLabel":self.nameLabel,
                            @"conversationLabel":self.conversationLabel,
                            @"accountLabel":self.accountLabel};
    
    NSDictionary *metrics = @{@"margin":[NSNumber numberWithFloat:OTRBuddyImageCellPadding],@"unreadMargin":[NSNumber numberWithFloat:5.0],@"conversationMargin":[NSNumber numberWithFloat:18.0]}; // unreadMargin
    // added conversationMargin
    if (!self.addedConstraints) {
        [self.contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:[unreadView]-unreadMargin-[imageView]-margin-[nameLabel]->=0-[dateLabel]-margin-|"
                                                                                 options:0
                                                                                 metrics:metrics
                                                                                   views:views]];
        
        [self.contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:[unreadView]-unreadMargin-[imageView]-margin-[conversationLabel]-margin-|"
                                                                                 options:0
                                                                                 metrics:metrics
                                                                                   views:views]];
        
        [self.contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-margin-[dateLabel(17)]" options:0 metrics:metrics
                                                                                   views:views]];
        
        
    }
    
    if([self.accountHorizontalConstraints count])
    {
        [self.contentView removeConstraints:self.accountHorizontalConstraints];
    }
    
    if([self.verticalConstraints count]) {
        [self.contentView removeConstraints:self.verticalConstraints];
    }
    
    if (self.showAccountLabel) {
        self.accountHorizontalConstraints = [NSLayoutConstraint constraintsWithVisualFormat:@"H:[unreadView]-margin-[imageView]-margin-[accountLabel]|"
                                                                                    options:0
                                                                                    metrics:metrics
                                                                                      views:views];
        
        self.verticalConstraints = [NSLayoutConstraint constraintsWithVisualFormat:@"V:|-margin-[nameLabel][conversationLabel][accountLabel]-margin-|"
                                                                           options:0
                                                                           metrics:metrics
                                                                             views:views];
        
    }
    else {
        self.accountHorizontalConstraints = @[];
        
        self.verticalConstraints = [NSLayoutConstraint constraintsWithVisualFormat:@"V:|-margin-[nameLabel(17)][conversationLabel]-conversationMargin-|"
                                                                           options:0
                                                                           metrics:metrics
                                                                             views:views];
    }
    if([self.accountHorizontalConstraints count]) {
        [self.contentView addConstraints:self.accountHorizontalConstraints];
    }
    
    [self.contentView addConstraints:self.verticalConstraints];
    [super updateConstraints];
}

@end
