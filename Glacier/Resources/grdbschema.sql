CREATE
    TABLE
        keyvalue (
            KEY TEXT NOT NULL
            ,collection TEXT NOT NULL
            ,VALUE BLOB NOT NULL
            ,PRIMARY KEY (
                KEY
                ,collection
            )
        )
;

CREATE
    TABLE
        IF NOT EXISTS "SMSAccount" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"twilioId" TEXT NOT NULL
            ,"phoneNumber" TEXT NOT NULL
            ,"displayName" TEXT
            ,"color" TEXT
            ,"modified" DATE
        )
;

CREATE
    TABLE
        IF NOT EXISTS "SMSConversation" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"smsAccountId" TEXT 
            ,"firstName" TEXT
            ,"lastName" TEXT
            ,"preferredName" TEXT
            ,"avatarData" BLOB
            ,"remoteNumber" TEXT
            ,"localNumber" TEXT
            ,"latestMessage" TEXT 
            ,"latestMessageId" TEXT
            ,"latestMessageDate" DOUBLE
            ,"isRead" INTEGER
            ,"isNew" INTEGER 
            ,"twilioId" TEXT
            ,"modified" DATE
            , CONSTRAINT fk_smsaccount
                FOREIGN KEY (smsAccountId)
                REFERENCES SMSAccount(uniqueId)
                ON DELETE CASCADE
        )
;

CREATE
    TABLE
        IF NOT EXISTS "SMSMessage" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"conversationId" TEXT
            ,"twilioSid" TEXT 
            ,"messageDate" DOUBLE
            ,"isRead" INTEGER
            ,"isIncoming" INTEGER 
            ,"mediaItemUniqueId" TEXT
            ,"transferProgress" DOUBLE
            ,"msgText" TEXT
            ,"msgSenderId" TEXT
            ,"msgSenderDisplayName" TEXT
            ,"modified" DATE
            , CONSTRAINT fk_smsconversation
                FOREIGN KEY (conversationId)
                REFERENCES SMSConversation(uniqueId)
                ON DELETE CASCADE
        )
;

CREATE
    TABLE
        IF NOT EXISTS "SMSMediaItem" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"parentObjectKey" TEXT NOT NULL
            ,"parentObjectCollection" TEXT
            ,"parentThreadKey" TEXT NOT NULL
            ,"transferProgress" DOUBLE 
            ,"filename" TEXT
            ,"modified" DATE
            , CONSTRAINT fk_smsmessage
                FOREIGN KEY (parentObjectKey)
                REFERENCES SMSMessage(uniqueId)
                ON DELETE CASCADE
        )
;

CREATE
    TABLE
        IF NOT EXISTS "CallRecord" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"twilioSid" TEXT
            ,"name" TEXT
            ,"phoneNumber" TEXT
            ,"isIncoming" BOOLEAN NOT NULL DEFAULT 1
            ,"to" TEXT
            ,"toFormatted" TEXT
            ,"from" TEXT
            ,"fromFormatted" TEXT
            ,"status" TEXT
            ,"startTime" TEXT
            ,"endTime" TEXT
            ,"duration" TEXT
            ,"modified" DATE
        )
;

CREATE
    INDEX "index_CallRecord_on_twilioSid"
        ON "CallRecord"("twilioSid"
)
;

CREATE
    INDEX "index_SMSAccount_on_uniqueId"
        ON "SMSAccount"("uniqueId"
)
;

CREATE
    INDEX "index_SMSMessage_on_uniqueId"
        ON "SMSMessage"("uniqueId"
)
;

CREATE
    INDEX "index_SMSMessage_on_conversationId"
        ON "SMSMessage"("conversationId"
)
;

CREATE
    INDEX "index_SMSMessage_on_messageDate"
        ON "SMSMessage"("messageDate"
)
;

CREATE
    INDEX "index_SMSConversation_on_uniqueId"
        ON "SMSConversation"("uniqueId"
)
;

CREATE
    INDEX "index_SMSConversation_on_localPhone_remotePhone"
        ON "SMSConversation"("localNumber"
    ,"remoteNumber"
)
;

CREATE
    INDEX "index_SMSConversation_on_twilioId"
        ON "SMSConversation"("twilioId"
)
;


CREATE
    TABLE
        IF NOT EXISTS "chatPreKey" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"accountKey" TEXT
            ,"keyId" INTEGER
            ,"keyData" BLOB
        )
;

CREATE
    INDEX "index_ChatPreKey_on_keyId_accountKey"
        ON "chatPreKey"("accountKey","keyId"
)
;

CREATE
    TABLE
        IF NOT EXISTS "chatSenderKey" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"accountKey" TEXT
            ,"name" TEXT
            ,"deviceId" INTEGER
            ,"groupId" TEXT
            ,"senderKey" BLOB
        )
;

CREATE
    TABLE
        IF NOT EXISTS "chatSignedPreKey" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"accountKey" TEXT
            ,"keyId" INTEGER
            ,"keyData" BLOB
        )
;

CREATE
    TABLE
        IF NOT EXISTS "chatSignalSession" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"accountKey" TEXT
            ,"name" TEXT
            ,"deviceId" INTEGER
            ,"sessionData" BLOB
        )
;

CREATE
    INDEX "index_ChatSignalSession_on_sessionKey"
        ON "chatSignalSession"("accountKey","name"
)
;

CREATE
    TABLE
        IF NOT EXISTS "chatAccountSignalIdentity" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"accountKey" TEXT
            ,"publicKey" BLOB
            ,"privateKey" BLOB
            ,"registrationId" INTEGER
        )
;

CREATE
    TABLE
        IF NOT EXISTS "chatRoomOccupant" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"jid" TEXT
            ,"chatRoomId" INTEGER
            ,"roomUniqueId" TEXT
            ,"buddyUniqueId" TEXT
            ,"realJid" TEXT
            ,"role" INTEGER
            ,"affiliation" INTEGER
            , FOREIGN KEY (chatRoomId)
                REFERENCES chatRoom(Id)
                ON DELETE CASCADE
        )
;

CREATE
    INDEX "index_chatRoomOccupant_on_roomUniqueId_jid_realJid"
        ON "chatRoomOccupant"("chatRoomId","jid","realJid"
)
;

CREATE
    TABLE
        IF NOT EXISTS "chatRoomMessage" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"chatRoomId" INTEGER NOT NULL
            ,"roomJid" TEXT
            ,"senderJid" TEXT
            ,"realJid" TEXT
            ,"receiverJid" TEXT
            ,"msgSenderId" TEXT
            ,"msgSenderDisplayName" TEXT
            ,"state" INTEGER
            ,"deliveredDate" DOUBLE
            ,"messageText" TEXT
            ,"originalText" TEXT
            ,"expires" TEXT
            ,"memberUpdate" BOOLEAN NOT NULL DEFAULT 0
            ,"systemUpdate" BOOLEAN NOT NULL DEFAULT 0
            ,"markable" BOOLEAN NOT NULL DEFAULT 0
            ,"isDisplayed" BOOLEAN NOT NULL DEFAULT 0
            ,"displayedJids" TEXT
            ,"displayedUpdate" BOOLEAN NOT NULL DEFAULT 0
            ,"messageDate" DOUBLE
            ,"messageReadDate" DOUBLE
            ,"xmppId" TEXT
            ,"read" BOOLEAN NOT NULL DEFAULT 1
            ,"error" INTEGER
            ,"mediaItemId" TEXT
            ,"mediaType" INTEGER
            ,"reactions" BLOB
            ,"transferProgress" DOUBLE
            ,"roomUniqueId" TEXT
            ,"originId" TEXT
            ,"stanzaId" TEXT
            ,"buddyUniqueId" TEXT
            ,"messageSecurity" INTEGER
            ,"omemoDeviceKey" TEXT
            ,"type" INTEGER
            ,"parentMessageKey" TEXT
            ,"parentMessageCollection" TEXT
            ,"url" TEXT
            ,"modified" DATE
            , FOREIGN KEY (chatRoomId)
                REFERENCES chatRoom(id)
                ON DELETE CASCADE
        )
;

CREATE
    INDEX "index_chatRoomMessage_on_read_threadId"
        ON "chatRoomMessage"("read","roomUniqueId"
)
;

CREATE
    INDEX "index_chatRoomMessage_on_type"
        ON "chatRoomMessage"("type"
)
;

CREATE
    INDEX "index_chatRoomMessage_on_parentMessageKey"
        ON "chatRoomMessage"("parentMessageKey"
)
;

CREATE
    INDEX "index_chatRoomMessage_on_threadId"
        ON "chatRoomMessage"("roomUniqueId"
)
;

CREATE
    INDEX "index_chatRoomMessage_on_uniqueId"
        ON "chatRoomMessage"("uniqueId"
)
;

CREATE
    INDEX "index_chatRoomMessage_on_roomJid_date"
        ON "chatRoomMessage"("roomJid", "messageDate"
)
;

CREATE
    UNIQUE INDEX "index_chatRoomMessage_unique_on_roomUniqueId_originId"
        ON "chatRoomMessage"("roomUniqueId", "originId"
)
    WHERE "originId" IS NOT NULL
;

CREATE
    TABLE
        IF NOT EXISTS "chatThread" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"accountUniqueId" TEXT
            ,"lastMessageId" TEXT
            ,"messageDate" DATE
            ,"isGroupThread" BOOLEAN NOT NULL DEFAULT 0
            ,"modified" DATE
            ,"isReadReceiptsOn" BOOLEAN NOT NULL DEFAULT 1
            , FOREIGN KEY (accountUniqueId)
                REFERENCES chatAccount(id)
                ON DELETE CASCADE
        )
;

CREATE
    TABLE
        IF NOT EXISTS "chatRoom" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"chatThreadId" INTEGER NOT NULL
            ,"lastHistoryFetch" DOUBLE
            ,"isArchived" BOOLEAN NOT NULL DEFAULT 0
            ,"muteExpiration" DOUBLE
            ,"accountUniqueId" TEXT
            ,"isPublic" BOOLEAN NOT NULL DEFAULT 0
            ,"preferredSecurity" INTEGER
            ,"roomJid" TEXT
            ,"ourJid" TEXT
            ,"messageText" TEXT
            ,"lastRoomMessageId" TEXT
            ,"subject" TEXT
            ,"roomName" TEXT
            ,"roomPassword" TEXT
            ,"currentMessageText" TEXT
            ,"modified" DATE
            , FOREIGN KEY (chatThreadId)
                REFERENCES chatThread(id)
                ON DELETE CASCADE
        )
;

CREATE
    INDEX "index_chatRoom_on_threadId"
        ON "chatRoom"("uniqueId"
)
;

CREATE
    TABLE
        IF NOT EXISTS "chatBuddy" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"chatThreadId" INTEGER NOT NULL
            ,"username" TEXT
            ,"displayName" TEXT
            ,"composingMessageString" TEXT
            ,"isArchived" BOOLEAN NOT NULL DEFAULT 0
            ,"muteExpiration" DOUBLE
            ,"currentMessageText" TEXT
            ,"expiresIn" TEXT
            ,"lastMessageId" TEXT
            ,"accountUniqueId" TEXT
            ,"avatarData" BLOB
            ,"subscription" INTEGER
            ,"pending" INTEGER
            ,"vCardTemp" BLOB
            ,"lastUpdatedvCardTemp" DOUBLE
            ,"photoHash" TEXT
            ,"modified" DATE
            ,"sharedGroups" TEXT
        )
;

CREATE
    INDEX "index_Buddy_on_accountKey_username"
        ON "chatBuddy"("accountUniqueId","username"
)
;

CREATE
    INDEX "index_Buddy_on_uniqueId"
        ON "chatBuddy"("uniqueId"
)
;

CREATE
    TABLE
        IF NOT EXISTS "chatMediaItem" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"parentObjectKey" TEXT
            ,"parentObjectCollection" TEXT
            ,"mimeType" TEXT
            ,"filename" TEXT
            ,"isIncoming" BOOLEAN NOT NULL DEFAULT 1
            ,"transferProgress" DOUBLE
            ,"size" BLOB
            ,"gifsize" BLOB
            ,"imageUrl" TEXT
            ,"linkTitle" TEXT
            ,"timeLength" DOUBLE
            ,"mediaType" INTEGER
        )
;

CREATE
    INDEX "index_MediaItem_on_transferProgress_incoming"
        ON "chatMediaItem"("transferProgress","isIncoming"
)
;

CREATE
    TABLE
        IF NOT EXISTS "chatMessage" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"chatBuddyId" INTEGER NOT NULL
            ,"msgSenderId" TEXT
            ,"msgSenderDisplayName" TEXT
            ,"date" DOUBLE
            ,"readDate" DOUBLE
            ,"text" TEXT
            ,"originalText" TEXT
            ,"expires" TEXT
            ,"xmppId" TEXT
            ,"error" INTEGER
            ,"systemUpdate" BOOLEAN NOT NULL DEFAULT 0
            ,"markable" BOOLEAN NOT NULL DEFAULT 0
            ,"mediaItemUniqueId" TEXT
            ,"messageMediaItemKey" TEXT
            ,"mediaType" INTEGER
            ,"reactions" BLOB
            ,"transferProgress" DOUBLE
            ,"buddyUniqueId" TEXT
            ,"originId" TEXT
            ,"stanzaId" TEXT
            ,"messageSecurity" INTEGER
            ,"omemoDeviceKey" TEXT
            ,"type" INTEGER
            ,"parentObjectKey" TEXT
            ,"parentObjectCollection" TEXT
            ,"url" TEXT
            ,"read" BOOLEAN NOT NULL DEFAULT 0
            ,"dateSent" DOUBLE
            ,"dateAcked" DOUBLE
            ,"dateDelivered" DOUBLE
            ,"outgoingFromDifferentDevice" BOOLEAN NOT NULL DEFAULT 0
            ,"delivered" BOOLEAN NOT NULL DEFAULT 0
            ,"displayed" BOOLEAN NOT NULL DEFAULT 0
            ,"dateDisplayed" DOUBLE
            ,"modified" DATE
            , FOREIGN KEY (chatBuddyId)
                REFERENCES chatBuddy(id)
                ON DELETE CASCADE
        )
;

CREATE
    INDEX "index_chatMessage_on_threadId"
        ON "chatMessage"("buddyUniqueId"
)
;

CREATE
    INDEX "index_chatMessage_on_uniqueId"
        ON "chatMessage"("uniqueId"
)
;

CREATE
    INDEX "index_chatMessage_on_read_threadId"
        ON "chatMessage"("read","buddyUniqueId"
)
;

CREATE
    INDEX "index_chatMessage_on_parentObjectKey"
        ON "chatMessage"("parentObjectKey"
)
;

CREATE
    INDEX "index_chatMessage_on_messageId_stanzaId_originId"
        ON "chatMessage"("xmppId","originId","stanzaId"
)
;

CREATE
    INDEX "index_chatMessage_on_buddyUniqueId_date"
        ON "chatMessage"("buddyUniqueId", "date"
)
;

CREATE
    UNIQUE INDEX "index_chatMessage_unique_on_buddyUniqueId_originId"
        ON "chatMessage"("buddyUniqueId", "originId"
)
    WHERE "originId" IS NOT NULL
;

CREATE
    TABLE
        IF NOT EXISTS "chatOmemoDevice" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"parentKey" TEXT
            ,"parentCollection" TEXT
            ,"deviceId" INTEGER
            ,"publicIdentityKeyData" BLOB
            ,"trustLevel" INTEGER
            ,"lastSeenDate" DOUBLE
        )
;

CREATE
    INDEX "index_chatOmemoDevice_on_parentKey_deviceId_collection"
        ON "chatOmemoDevice"("parentKey","deviceId"
)
;

CREATE
    TABLE
        IF NOT EXISTS "chatAccount" (
            "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL
            ,"uniqueId" TEXT NOT NULL UNIQUE
                ON CONFLICT FAIL
            ,"username" TEXT
            ,"domain" TEXT
            ,"resource" TEXT
            ,"port" INTEGER
            ,"accountType" INTEGER
            ,"displayName" TEXT
            ,"rememberPassword" BOOLEAN NOT NULL DEFAULT 1
            ,"autologin" BOOLEAN NOT NULL DEFAULT 1
            ,"bypassNetworkCheck" BOOLEAN NOT NULL DEFAULT 1
            ,"useStageConsole" BOOLEAN NOT NULL DEFAULT 0
            ,"disableAutomaticURLFetching" BOOLEAN NOT NULL DEFAULT 0
            ,"smsEnabled" BOOLEAN NOT NULL DEFAULT 0
            ,"rebootReminderEnabled" BOOLEAN NOT NULL DEFAULT 1
            ,"trackingEnabled" BOOLEAN NOT NULL DEFAULT 0
            ,"forceTracking" BOOLEAN NOT NULL DEFAULT 0
            ,"trackingOn" BOOLEAN NOT NULL DEFAULT 0
            ,"isReadReceiptsOn" BOOLEAN NOT NULL DEFAULT 1
            ,"trackingInterval" INTEGER DEFAULT 300
            ,"loginDate" DOUBLE
            ,"lastHistoryFetchDate" DOUBLE
            ,"pushPubsubEndpoint" TEXT
            ,"pushPubsubNode" TEXT
            ,"org" TEXT
            ,"apiKey" TEXT
            ,"vCardTemp" BLOB
            ,"lastUpdatedvCardTemp" DOUBLE
            ,"photoHash" TEXT
            ,"avatarData" BLOB
            ,"password" TEXT
            ,"modified" DATE
        )
;

CREATE
    INDEX "index_Account_on_accountKey"
        ON "chatAccount"("uniqueId"
)
;
