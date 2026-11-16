/**
 * @description Correlates Watched Object Field History timestamps with active Login-As impersonation windows
 * from SetupAuditTrail, ingested Auditr_Entry__c records, and AuthSession substitute sessions.
 */
public with sharing class AuditrLoginAsCorrelator {
    public static final Integer DEFAULT_LOGIN_AS_MAX_MINUTES = 120;
    private static final Integer SIGNAL_QUERY_LIMIT = 5000;
    private static final String LOGIN_AS_DISPLAY_MARKER = ' login-as access for ';

    private static final Set<String> LOGIN_ACTIONS = new Set<String>{
        'suorgadminlogin',
        'sunetworkadminlogin',
        'suloginaccessused'
    };
    private static final Set<String> LOGOUT_ACTIONS = new Set<String>{
        'suorgadminlogout',
        'sunetworkadminlogout',
        'sulogout'
    };
    private static final Set<String> ALL_SU_ACTIONS = new Set<String>{
        'suOrgAdminLogin',
        'suOrgAdminLogout',
        'suNetworkAdminLogin',
        'suNetworkAdminLogout',
        'suloginaccessused',
        'suLogout'
    };

    @TestVisible private static List<LoginAsWindow> testWindowsOverride;

    /** @description Time window representing an active Login-As impersonation session. */
    public class LoginAsWindow {
        public Id actorId;
        public String actorUsername;
        public String delegateUser;
        public DateTime startAt;
        public DateTime endAt;

        /**
         * @description Constructs a Login-As correlation window.
         * @param actorId Impersonated user ID.
         * @param actorUsername Impersonated username or display target.
         * @param delegateUser Admin/support username who initiated Login-As.
         * @param startAt Window start timestamp.
         * @param endAt Window end timestamp.
         */
        @SuppressWarnings('PMD.ExcessiveParameterList')
        public LoginAsWindow(
            Id actorId,
            String actorUsername,
            String delegateUser,
            DateTime startAt,
            DateTime endAt
        ) {
            this.actorId = actorId;
            this.actorUsername = actorUsername;
            this.delegateUser = delegateUser;
            this.startAt = startAt;
            this.endAt = endAt;
        }

        /**
         * @description Checks whether a history event for the given actor and timestamp falls inside this window.
         * @param candidateActorId Actor User ID from the Field History row.
         * @param candidateActorUsername Actor Username from the Field History row.
         * @param occurredAt Timestamp of the Field History row.
         * @return True when the event falls within [startAt, endAt] for the same impersonated user.
         */
        public Boolean matches(Id candidateActorId, String candidateActorUsername, DateTime occurredAt) {
            if (!isWithinTimeRange(occurredAt)) {
                return false;
            }
            return matchesActor(candidateActorId, candidateActorUsername);
        }

        private Boolean isWithinTimeRange(DateTime occurredAt) {
            return occurredAt != null
                && String.isNotBlank(this.delegateUser)
                && this.startAt != null
                && this.endAt != null
                && occurredAt >= this.startAt
                && occurredAt <= this.endAt;
        }

        private Boolean matchesActor(Id candidateActorId, String candidateActorUsername) {
            if (this.actorId != null && candidateActorId != null) {
                return this.actorId == candidateActorId;
            }
            if (String.isNotBlank(this.actorUsername) && String.isNotBlank(candidateActorUsername)) {
                return this.actorUsername.trim().equalsIgnoreCase(candidateActorUsername.trim());
            }
            return false;
        }
    }

    private class RawSignal {
        public String actionCode;
        public Id createdById;
        public String createdByUsername;
        public String delegateUser;
        public String displayText;
        public DateTime occurredAt;
    }

    /**
     * @description Resolves the inferred Delegate User if the event timestamp falls inside an active Login-As window.
     * @param windows Active LoginAsWindow list for the current batch scope.
     * @param actorId Actor User ID on the Field History row.
     * @param actorUsername Actor Username on the Field History row.
     * @param occurredAt Timestamp of the Field History row.
     * @return Inferred admin username, or null when not inside a Login-As window.
     */
    @SuppressWarnings('PMD.ExcessiveParameterList')
    public static String resolveDelegateUser(
        List<LoginAsWindow> windows,
        Id actorId,
        String actorUsername,
        DateTime occurredAt
    ) {
        List<LoginAsWindow> effectiveWindows = (testWindowsOverride != null) ? testWindowsOverride : windows;
        if (effectiveWindows == null || effectiveWindows.isEmpty() || occurredAt == null) {
            return null;
        }
        for (LoginAsWindow win : effectiveWindows) {
            if (win != null && win.matches(actorId, actorUsername, occurredAt)) {
                return win.delegateUser;
            }
        }
        return null;
    }

    /**
     * @description Loads Login-As windows covering the bounded time range [earliest - 120m, latest + 5m].
     * @param earliest Earliest history row timestamp in the chunk.
     * @param latest Latest history row timestamp in the chunk.
     * @return Ordered list of LoginAsWindow instances.
     */
    public static List<LoginAsWindow> loadWindowsForRange(DateTime earliest, DateTime latest) {
        if (testWindowsOverride != null) {
            return testWindowsOverride;
        }
        DateTime anchorStart = (earliest != null) ? earliest : System.now();
        DateTime anchorEnd = (latest != null && latest >= anchorStart) ? latest : anchorStart;
        DateTime queryStart = anchorStart.addMinutes(-DEFAULT_LOGIN_AS_MAX_MINUTES);
        DateTime queryEnd = anchorEnd.addMinutes(5);

        List<RawSignal> signals = collectSignals(queryStart, queryEnd);
        Map<String, User> usersByNameOrUsername = resolveDisplayTargetUsers(signals);
        List<LoginAsWindow> windows = buildWindowsFromSignals(signals, usersByNameOrUsername);
        windows.addAll(loadSubstituteAuthSessionWindows(queryStart, queryEnd));
        return windows;
    }

    private static List<RawSignal> collectSignals(DateTime queryStart, DateTime queryEnd) {
        List<RawSignal> signals = new List<RawSignal>();
        Set<String> seenSourceIds = new Set<String>();

        for (Auditr_Entry__c entry : [
            SELECT Source_Record_Id__c, Action_Code__c, Actor__c, Actor_Username__c,
                   Delegate_User__c, Display__c, Occurred_At__c
            FROM Auditr_Entry__c
            WHERE Source__c = :AuditrUtil.DEFAULT_SOURCE
              AND Occurred_At__c >= :queryStart
              AND Occurred_At__c <= :queryEnd
              AND (Delegate_User__c != NULL OR Action_Code__c IN :ALL_SU_ACTIONS)
            WITH SYSTEM_MODE
            ORDER BY Occurred_At__c ASC, Name ASC
            LIMIT :SIGNAL_QUERY_LIMIT
        ]) {
            if (String.isNotBlank(entry.Source_Record_Id__c)) {
                seenSourceIds.add(entry.Source_Record_Id__c);
            }
            RawSignal sig = new RawSignal();
            sig.actionCode = entry.Action_Code__c;
            sig.createdById = entry.Actor__c;
            sig.createdByUsername = entry.Actor_Username__c;
            sig.delegateUser = entry.Delegate_User__c;
            sig.displayText = entry.Display__c;
            sig.occurredAt = entry.Occurred_At__c;
            signals.add(sig);
        }

        for (SetupAuditTrail sat : [
            SELECT Id, Action, CreatedById, CreatedBy.Username, DelegateUser, Display, CreatedDate
            FROM SetupAuditTrail
            WHERE CreatedDate >= :queryStart
              AND CreatedDate <= :queryEnd
              AND (DelegateUser != NULL OR Action IN :ALL_SU_ACTIONS)
            WITH SYSTEM_MODE
            ORDER BY CreatedDate ASC, Id ASC
            LIMIT :SIGNAL_QUERY_LIMIT
        ]) {
            if (seenSourceIds.contains(String.valueOf(sat.Id))) {
                continue;
            }
            RawSignal sig = new RawSignal();
            sig.actionCode = sat.Action;
            sig.createdById = sat.CreatedById;
            sig.createdByUsername = (sat.CreatedBy != null) ? sat.CreatedBy.Username : null;
            sig.delegateUser = sat.DelegateUser;
            sig.displayText = sat.Display;
            sig.occurredAt = sat.CreatedDate;
            signals.add(sig);
        }
        return signals;
    }

    private static Map<String, User> resolveDisplayTargetUsers(List<RawSignal> signals) {
        Set<String> targetTokens = new Set<String>();
        for (RawSignal sig : signals) {
            String extracted = extractTargetFromDisplay(sig.displayText);
            if (String.isNotBlank(extracted)) {
                targetTokens.add(extracted);
            }
        }
        Map<String, User> byKey = new Map<String, User>();
        if (targetTokens.isEmpty()) {
            return byKey;
        }
        for (User usr : [
            SELECT Id, Username, Name
            FROM User
            WHERE Username IN :targetTokens OR Name IN :targetTokens
            WITH SYSTEM_MODE
        ]) {
            if (String.isNotBlank(usr.Username)) {
                byKey.put(usr.Username.trim().toLowerCase(), usr);
            }
            if (String.isNotBlank(usr.Name)) {
                byKey.put(usr.Name.trim().toLowerCase(), usr);
            }
        }
        return byKey;
    }

    private static List<LoginAsWindow> buildWindowsFromSignals(
        List<RawSignal> signals,
        Map<String, User> usersByNameOrUsername
    ) {
        List<LoginAsWindow> windows = new List<LoginAsWindow>();
        Map<String, LoginAsWindow> openByActorKey = new Map<String, LoginAsWindow>();

        for (RawSignal sig : signals) {
            ResolvedParticipants participants = resolveParticipants(sig, usersByNameOrUsername);
            if (participants == null) {
                continue;
            }
            applySignal(windows, openByActorKey, sig.actionCode, sig.occurredAt, participants);
        }
        return windows;
    }

    private class ResolvedParticipants {
        public Id actorId;
        public String actorUsername;
        public String delegateUser;
        public String actorKey;
    }

    private static ResolvedParticipants resolveParticipants(
        RawSignal sig,
        Map<String, User> usersByNameOrUsername
    ) {
        if (sig == null || sig.occurredAt == null) {
            return null;
        }
        ResolvedParticipants res = buildParticipantFromSignal(sig, usersByNameOrUsername);
        if (res == null) {
            return null;
        }
        res.actorKey = resolveActorKey(res.actorId, res.actorUsername);
        return String.isNotBlank(res.actorKey) ? res : null;
    }

    private static ResolvedParticipants buildParticipantFromSignal(
        RawSignal sig,
        Map<String, User> usersByNameOrUsername
    ) {
        if (hasDistinctDelegate(sig)) {
            ResolvedParticipants res = new ResolvedParticipants();
            res.actorId = sig.createdById;
            res.actorUsername = sig.createdByUsername;
            res.delegateUser = sig.delegateUser.trim();
            return res;
        }
        String displayTarget = extractTargetFromDisplay(sig.displayText);
        if (String.isBlank(displayTarget) || String.isBlank(sig.createdByUsername)) {
            return null;
        }
        User matchedUser = usersByNameOrUsername.get(displayTarget.toLowerCase());
        ResolvedParticipants res = new ResolvedParticipants();
        res.actorId = (matchedUser != null) ? matchedUser.Id : null;
        res.actorUsername = (matchedUser != null) ? matchedUser.Username : displayTarget;
        res.delegateUser = sig.createdByUsername.trim();
        return res;
    }

    private static Boolean hasDistinctDelegate(RawSignal sig) {
        if (String.isBlank(sig.delegateUser)) {
            return false;
        }
        String createdBy = (sig.createdByUsername != null) ? sig.createdByUsername.trim() : '';
        return !sig.delegateUser.trim().equalsIgnoreCase(createdBy);
    }

    private static String resolveActorKey(Id actorId, String actorUsername) {
        if (actorId != null) {
            return String.valueOf(actorId);
        }
        return String.isNotBlank(actorUsername) ? actorUsername.trim().toLowerCase() : null;
    }

    @SuppressWarnings('PMD.ExcessiveParameterList')
    private static void applySignal(
        List<LoginAsWindow> windows,
        Map<String, LoginAsWindow> openByActorKey,
        String actionCode,
        DateTime occurredAt,
        ResolvedParticipants p
    ) {
        String normalizedAction = String.isNotBlank(actionCode) ? actionCode.trim().toLowerCase() : '';
        if (LOGIN_ACTIONS.contains(normalizedAction)) {
            LoginAsWindow prevOpen = openByActorKey.get(p.actorKey);
            if (prevOpen != null && prevOpen.endAt > occurredAt) {
                prevOpen.endAt = occurredAt;
            }
            LoginAsWindow nextWin = new LoginAsWindow(
                p.actorId,
                p.actorUsername,
                p.delegateUser,
                occurredAt,
                occurredAt.addMinutes(DEFAULT_LOGIN_AS_MAX_MINUTES)
            );
            windows.add(nextWin);
            openByActorKey.put(p.actorKey, nextWin);
            return;
        }
        if (LOGOUT_ACTIONS.contains(normalizedAction)) {
            LoginAsWindow openWin = openByActorKey.remove(p.actorKey);
            if (openWin != null) {
                openWin.endAt = occurredAt;
            } else {
                windows.add(new LoginAsWindow(
                    p.actorId,
                    p.actorUsername,
                    p.delegateUser,
                    occurredAt.addMinutes(-DEFAULT_LOGIN_AS_MAX_MINUTES),
                    occurredAt
                ));
            }
            return;
        }
        LoginAsWindow openWin = openByActorKey.get(p.actorKey);
        if (openWin == null || occurredAt > openWin.endAt) {
            LoginAsWindow activityWin = new LoginAsWindow(
                p.actorId,
                p.actorUsername,
                p.delegateUser,
                occurredAt.addMinutes(-5),
                occurredAt.addMinutes(30)
            );
            windows.add(activityWin);
            openByActorKey.put(p.actorKey, activityWin);
        }
    }

    @TestVisible
    private static String extractTargetFromDisplay(String displayText) {
        if (String.isBlank(displayText)) {
            return null;
        }
        String lower = displayText.toLowerCase();
        Integer markerIdx = lower.indexOf(LOGIN_AS_DISPLAY_MARKER);
        if (markerIdx < 0) {
            return null;
        }
        String rawTarget = displayText.substring(markerIdx + LOGIN_AS_DISPLAY_MARKER.length()).trim();
        while (rawTarget.endsWith('.') || rawTarget.endsWith('"') || rawTarget.endsWith('\'')) {
            rawTarget = rawTarget.substring(0, rawTarget.length() - 1).trim();
        }
        return String.isNotBlank(rawTarget) ? rawTarget : null;
    }

    private static List<LoginAsWindow> loadSubstituteAuthSessionWindows(DateTime queryStart, DateTime queryEnd) {
        List<LoginAsWindow> sessionWindows = new List<LoginAsWindow>();
        List<AuthSession> subSessions = [
            SELECT Id, UsersId, Users.Username, ParentId, CreatedDate, LastModifiedDate
            FROM AuthSession
            WHERE (SessionType = 'SubstituteUser' OR LoginType = 'SysAdmin Switch')
              AND ParentId != NULL
              AND CreatedDate <= :queryEnd
              AND LastModifiedDate >= :queryStart
            WITH SYSTEM_MODE
            LIMIT 500
        ];
        if (subSessions.isEmpty()) {
            return sessionWindows;
        }
        Map<Id, String> adminUsernameBySessionId = queryAdminUsernameBySessionId(subSessions);
        for (AuthSession sub : subSessions) {
            LoginAsWindow sessionWin = buildWindowFromAuthSession(sub, adminUsernameBySessionId.get(sub.ParentId));
            if (sessionWin != null) {
                sessionWindows.add(sessionWin);
            }
        }
        return sessionWindows;
    }

    private static Map<Id, String> queryAdminUsernameBySessionId(List<AuthSession> subSessions) {
        Set<Id> parentSessionIds = new Set<Id>();
        for (AuthSession sub : subSessions) {
            if (sub.ParentId != null) {
                parentSessionIds.add(sub.ParentId);
            }
        }
        Map<Id, String> adminUsernameBySessionId = new Map<Id, String>();
        for (AuthSession parentSession : [
            SELECT Id, Users.Username
            FROM AuthSession
            WHERE Id IN :parentSessionIds
            WITH SYSTEM_MODE
        ]) {
            if (parentSession.Users != null && String.isNotBlank(parentSession.Users.Username)) {
                adminUsernameBySessionId.put(parentSession.Id, parentSession.Users.Username);
            }
        }
        return adminUsernameBySessionId;
    }

    private static LoginAsWindow buildWindowFromAuthSession(AuthSession sub, String adminUsername) {
        if (String.isBlank(adminUsername) || sub.UsersId == null) {
            return null;
        }
        String impUsername = (sub.Users != null) ? sub.Users.Username : null;
        DateTime endAt = (sub.LastModifiedDate != null && sub.LastModifiedDate > sub.CreatedDate)
            ? sub.LastModifiedDate.addMinutes(15)
            : sub.CreatedDate.addMinutes(DEFAULT_LOGIN_AS_MAX_MINUTES);
        return new LoginAsWindow(sub.UsersId, impUsername, adminUsername, sub.CreatedDate, endAt);
    }
}
